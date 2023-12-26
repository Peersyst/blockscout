defmodule Indexer.Fetcher.Zkevm.Bridge do
  @moduledoc """
  Contains common functions for Indexer.Fetcher.Zkevm.Bridge* modules.
  """

  require Logger

  import Ecto.Query

  import EthereumJSONRPC,
    only: [
      integer_to_quantity: 1,
      json_rpc: 2,
      quantity_to_integer: 1,
      request: 1
    ]

  import Explorer.Chain.SmartContract, only: [burn_address_hash_string: 0]

  import Explorer.Helper, only: [decode_data: 2]

  alias EthereumJSONRPC.Block.ByNumber
  alias EthereumJSONRPC.{Blocks, Logs}
  alias Explorer.Chain.Hash
  alias Explorer.Chain.Zkevm.BridgeL1Token
  alias Explorer.{Chain, Repo}
  alias Explorer.SmartContract.Reader
  alias Indexer.Helper
  alias Indexer.Transform.Addresses

  # 32-byte signature of the event BridgeEvent(uint8 leafType, uint32 originNetwork, address originAddress, uint32 destinationNetwork, address destinationAddress, uint256 amount, bytes metadata, uint32 depositCount)
  @bridge_event "0x501781209a1f8899323b96b4ef08b168df93e0a90c673d1e4cce39366cb62f9b"
  @bridge_event_params [{:uint, 8}, {:uint, 32}, :address, {:uint, 32}, :address, {:uint, 256}, :bytes, {:uint, 32}]

  # 32-byte signature of the event ClaimEvent(uint32 index, uint32 originNetwork, address originAddress, address destinationAddress, uint256 amount)
  @claim_event "0x25308c93ceeed162da955b3f7ce3e3f93606579e40fb92029faa9efe27545983"
  @claim_event_params [{:uint, 32}, {:uint, 32}, :address, :address, {:uint, 256}]

  @erc20_abi [
    %{
      "constant" => true,
      "inputs" => [],
      "name" => "symbol",
      "outputs" => [%{"name" => "", "type" => "string"}],
      "payable" => false,
      "stateMutability" => "view",
      "type" => "function"
    },
    %{
      "constant" => true,
      "inputs" => [],
      "name" => "decimals",
      "outputs" => [%{"name" => "", "type" => "uint8"}],
      "payable" => false,
      "stateMutability" => "view",
      "type" => "function"
    }
  ]

  @spec filter_bridge_events(list(), binary()) :: list()
  def filter_bridge_events(events, bridge_contract) do
    Enum.filter(events, fn event ->
      String.downcase(event.address_hash) == bridge_contract and
        Enum.member?([@bridge_event, @claim_event], Helper.log_topic_to_string(event.first_topic))
    end)
  end

  @spec get_logs_all({non_neg_integer(), non_neg_integer()}, binary(), list()) :: list()
  def get_logs_all({chunk_start, chunk_end}, bridge_contract, json_rpc_named_arguments) do
    {:ok, result} =
      get_logs(
        chunk_start,
        chunk_end,
        bridge_contract,
        [[@bridge_event, @claim_event]],
        json_rpc_named_arguments
      )

    Logs.elixir_to_params(result)
  end

  defp get_logs(from_block, to_block, address, topics, json_rpc_named_arguments, retries \\ 100_000_000) do
    processed_from_block = if is_integer(from_block), do: integer_to_quantity(from_block), else: from_block
    processed_to_block = if is_integer(to_block), do: integer_to_quantity(to_block), else: to_block

    req =
      request(%{
        id: 0,
        method: "eth_getLogs",
        params: [
          %{
            :fromBlock => processed_from_block,
            :toBlock => processed_to_block,
            :address => address,
            :topics => topics
          }
        ]
      })

    error_message = &"Cannot fetch logs for the block range #{from_block}..#{to_block}. Error: #{inspect(&1)}"

    Helper.repeated_call(&json_rpc/2, [req, json_rpc_named_arguments], error_message, retries)
  end

  @spec import_operations(list()) :: no_return()
  def import_operations(operations) do
    # here we explicitly check CHAIN_TYPE as Dialyzer throws an error otherwise
    import_options =
      if System.get_env("CHAIN_TYPE") == "polygon_zkevm" do
        addresses =
          Addresses.extract_addresses(%{
            zkevm_bridge_operations: operations
          })

        %{
          addresses: %{params: addresses, on_conflict: :nothing},
          zkevm_bridge_operations: %{params: operations},
          timeout: :infinity
        }
      else
        %{}
      end

    {:ok, _} = Chain.import(import_options)
  end

  @spec json_rpc_named_arguments(binary()) :: list()
  def json_rpc_named_arguments(rpc_url) do
    [
      transport: EthereumJSONRPC.HTTP,
      transport_options: [
        http: EthereumJSONRPC.HTTP.HTTPoison,
        url: rpc_url,
        http_options: [
          recv_timeout: :timer.minutes(10),
          timeout: :timer.minutes(10),
          hackney: [pool: :ethereum_jsonrpc]
        ]
      ]
    ]
  end

  @spec prepare_operations(list(), list() | nil, list(), map() | nil) :: list()
  def prepare_operations(events, json_rpc_named_arguments, json_rpc_named_arguments_l1, block_to_timestamp \\ nil) do
    is_l1 = (json_rpc_named_arguments == json_rpc_named_arguments_l1)

    bridge_events = Enum.filter(events, fn event -> event.first_topic == @bridge_event end)

    block_to_timestamp =
      if is_nil(block_to_timestamp) do
        blocks_to_timestamps(bridge_events, json_rpc_named_arguments)
      else
        block_to_timestamp
      end

    token_address_to_id = token_addresses_to_ids(bridge_events, json_rpc_named_arguments_l1)

    Enum.map(events, fn event ->
      {type, index, l1_token_id, l2_token_address, amount, block_number, block_timestamp} =
        if event.first_topic == @bridge_event do
          [
            leaf_type,
            origin_network,
            origin_address,
            _destination_network,
            _destination_address,
            amount,
            _metadata,
            deposit_count
          ] = decode_data(event.data, @bridge_event_params)

          {l1_token_address, l2_token_address} =
            token_address_by_origin_address(origin_address, origin_network, leaf_type)

          l1_token_id = Map.get(token_address_to_id, l1_token_address)
          block_number = quantity_to_integer(event.block_number)
          block_timestamp = Map.get(block_to_timestamp, block_number)

          type =
            if is_l1 do
              :deposit
            else
              :withdrawal
            end

          {type, deposit_count, l1_token_id, l2_token_address, amount, block_number, block_timestamp}
        else
          [index, _origin_network, _origin_address, _destination_address, amount] =
            decode_data(event.data, @claim_event_params)

          type =
            if is_l1 do
              :withdrawal
            else
              :deposit
            end

          {type, index, nil, nil, amount, nil, nil}
        end

      result = %{
        type: type,
        index: index,
        amount: amount
      }

      transaction_hash_field =
        if is_l1 do
          :l1_transaction_hash
        else
          :l2_transaction_hash
        end

      result
      |> extend_result(transaction_hash_field, event.transaction_hash)
      |> extend_result(:l1_token_id, l1_token_id)
      |> extend_result(:l2_token_address, l2_token_address)
      |> extend_result(:block_number, block_number)
      |> extend_result(:block_timestamp, block_timestamp)
    end)
  end

  defp blocks_to_timestamps(events, json_rpc_named_arguments) do
    events
    |> get_blocks_by_events(json_rpc_named_arguments, 100_000_000)
    |> Enum.reduce(%{}, fn block, acc ->
      block_number = quantity_to_integer(Map.get(block, "number"))
      {:ok, timestamp} = DateTime.from_unix(quantity_to_integer(Map.get(block, "timestamp")))
      Map.put(acc, block_number, timestamp)
    end)
  end

  defp get_blocks_by_events(events, json_rpc_named_arguments, retries) do
    request =
      events
      |> Enum.reduce(%{}, fn event, acc ->
        Map.put(acc, event.block_number, 0)
      end)
      |> Stream.map(fn {block_number, _} -> %{number: block_number} end)
      |> Stream.with_index()
      |> Enum.into(%{}, fn {params, id} -> {id, params} end)
      |> Blocks.requests(&ByNumber.request(&1, false, false))

    error_message = &"Cannot fetch blocks with batch request. Error: #{inspect(&1)}. Request: #{inspect(request)}"

    case Helper.repeated_call(&json_rpc/2, [request, json_rpc_named_arguments], error_message, retries) do
      {:ok, results} -> Enum.map(results, fn %{result: result} -> result end)
      {:error, _} -> []
    end
  end

  defp token_addresses_to_ids(events, json_rpc_named_arguments) do
    token_data =
      events
      |> Enum.reduce(%MapSet{}, fn event, acc ->
        [
          leaf_type,
          origin_network,
          origin_address,
          _destination_network,
          _destination_address,
          _amount,
          _metadata,
          _deposit_count
        ] = decode_data(event.data, @bridge_event_params)

        case token_address_by_origin_address(origin_address, origin_network, leaf_type) do
          {nil, _} -> acc
          {token_address, nil} -> MapSet.put(acc, token_address)
        end
      end)
      |> MapSet.to_list()
      |> get_token_data(json_rpc_named_arguments)

    tokens_existing =
      token_data
      |> Map.keys()
      |> token_addresses_to_ids_from_db()

    tokens_to_insert =
      token_data
      |> Enum.reject(fn {address, _} -> Map.has_key?(tokens_existing, address) end)
      |> Enum.map(fn {address, data} -> Map.put(data, :address, address) end)

    # here we explicitly check CHAIN_TYPE as Dialyzer throws an error otherwise
    import_options =
      if System.get_env("CHAIN_TYPE") == "polygon_zkevm" do
        %{
          zkevm_bridge_l1_tokens: %{params: tokens_to_insert},
          timeout: :infinity
        }
      else
        %{}
      end

    {:ok, inserts} = Chain.import(import_options)

    tokens_inserted = Map.get(inserts, :insert_zkevm_bridge_l1_tokens, [])

    # we need to query uninserted tokens from DB separately as they
    # could be inserted by another module at the same time (a race condition).
    # this is an unlikely case but we handle it here as well
    tokens_uninserted =
      tokens_to_insert
      |> Enum.reject(fn token ->
        Enum.any?(tokens_inserted, fn inserted -> token.address == Hash.to_string(inserted.address) end)
      end)
      |> Enum.map(& &1.address)

    tokens_inserted_outside = token_addresses_to_ids_from_db(tokens_uninserted)

    tokens_inserted
    |> Enum.reduce(%{}, fn t, acc -> Map.put(acc, Hash.to_string(t.address), t.id) end)
    |> Map.merge(tokens_existing)
    |> Map.merge(tokens_inserted_outside)
  end

  defp token_addresses_to_ids_from_db(addresses) do
    query = from(t in BridgeL1Token, select: {t.address, t.id}, where: t.address in ^addresses)

    query
    |> Repo.all(timeout: :infinity)
    |> Enum.reduce(%{}, fn {address, id}, acc -> Map.put(acc, Hash.to_string(address), id) end)
  end

  defp token_address_by_origin_address(origin_address, origin_network, leaf_type) do
    with true <- leaf_type != 1 and origin_network <= 1,
         token_address = "0x" <> Base.encode16(origin_address, case: :lower),
         true <- token_address != burn_address_hash_string() do
      if origin_network == 0 do
        # this is L1 address
        {token_address, nil}
      else
        # this is L2 address
        {nil, token_address}
      end
    else
      _ -> {nil, nil}
    end
  end

  defp get_token_data(token_addresses, json_rpc_named_arguments) do
    # first, we're trying to read token data from the DB.
    # if tokens are not in the DB, read them through RPC.
    token_addresses
    |> get_token_data_from_db()
    |> get_token_data_from_rpc(json_rpc_named_arguments)
  end

  defp get_token_data_from_db(token_addresses) do
    # try to read token symbols and decimals from the database
    query =
      from(
        t in BridgeL1Token,
        where: t.address in ^token_addresses,
        select: {t.address, t.decimals, t.symbol}
      )

    token_data =
      query
      |> Repo.all()
      |> Enum.reduce(%{}, fn {address, decimals, symbol}, acc ->
        token_address = String.downcase(Hash.to_string(address))
        Map.put(acc, token_address, %{symbol: symbol, decimals: decimals})
      end)

    token_addresses_for_rpc =
      token_addresses
      |> Enum.reject(fn address ->
        Map.has_key?(token_data, String.downcase(address))
      end)

    {token_data, token_addresses_for_rpc}
  end

  defp get_token_data_from_rpc({token_data, token_addresses}, json_rpc_named_arguments) do
    {requests, responses} = get_token_data_request_symbol_decimals(token_addresses, json_rpc_named_arguments)

    requests
    |> Enum.zip(responses)
    |> Enum.reduce(token_data, fn {request, {status, response} = _resp}, token_data_acc ->
      if status == :ok do
        response = parse_response(response)

        address = String.downcase(request.contract_address)

        new_data = get_new_data(token_data_acc[address] || %{}, request, response)

        Map.put(token_data_acc, address, new_data)
      else
        token_data_acc
      end
    end)
  end

  defp get_token_data_request_symbol_decimals(token_addresses, json_rpc_named_arguments) do
    requests =
      token_addresses
      |> Enum.map(fn address ->
        # we will call symbol() and decimals() public getters
        Enum.map(["95d89b41", "313ce567"], fn method_id ->
          %{
            contract_address: address,
            method_id: method_id,
            args: []
          }
        end)
      end)
      |> List.flatten()

    {responses, error_messages} = read_contracts_with_retries(requests, @erc20_abi, json_rpc_named_arguments, 3)

    if !Enum.empty?(error_messages) or Enum.count(requests) != Enum.count(responses) do
      Logger.warning(
        "Cannot read symbol and decimals of an ERC-20 token contract. Error messages: #{Enum.join(error_messages, ", ")}. Addresses: #{Enum.join(token_addresses, ", ")}"
      )
    end

    {requests, responses}
  end

  defp read_contracts_with_retries(requests, abi, json_rpc_named_arguments, retries_left) when retries_left > 0 do
    responses = Reader.query_contracts(requests, abi, json_rpc_named_arguments: json_rpc_named_arguments)

    error_messages =
      Enum.reduce(responses, [], fn {status, error_message}, acc ->
        acc ++
          if status == :error do
            [error_message]
          else
            []
          end
      end)

    if Enum.empty?(error_messages) do
      {responses, []}
    else
      retries_left = retries_left - 1

      if retries_left == 0 do
        {responses, Enum.uniq(error_messages)}
      else
        :timer.sleep(1000)
        read_contracts_with_retries(requests, abi, json_rpc_named_arguments, retries_left)
      end
    end
  end

  defp get_new_data(data, request, response) do
    if atomized_key(request.method_id) == :symbol do
      Map.put(data, :symbol, response)
    else
      Map.put(data, :decimals, response)
    end
  end

  defp extend_result(result, _key, value) when is_nil(value), do: result
  defp extend_result(result, key, value) when is_atom(key), do: Map.put(result, key, value)

  defp atomized_key("symbol"), do: :symbol
  defp atomized_key("decimals"), do: :decimals
  defp atomized_key("95d89b41"), do: :symbol
  defp atomized_key("313ce567"), do: :decimals

  defp parse_response(response) do
    case response do
      [item] -> item
      items -> items
    end
  end
end