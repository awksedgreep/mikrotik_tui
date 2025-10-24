defmodule MikrotikTui.DataCache do
  @moduledoc """
  Polls mikrotik_api at configured intervals and caches latest data in state.
  Provides synchronous getters for UI to render without blocking on network.
  """
  use GenServer
  require Logger
  alias MikrotikApi.Auth

  @type state :: %{
          auth: Auth.t(),
          ip: String.t(),
          scheme: :http | :https,
          refresh_ms: pos_integer(),
          # cached data
          system_resource: any(),
          interfaces: [map()] | nil,
          dhcp_leases: any(),
          arp: any(),
          routes: any(),
          firewall: any(),
          nat: any(),
          nat_sessions: any(),
          errors: [map()],
          # live rates and sampling state
          rate_map: %{optional(String.t()) => %{rx_bps: non_neg_integer(), tx_bps: non_neg_integer(), link: String.t() | nil}},
          iface_cycle: [String.t()],
          cycle_pos: non_neg_integer(),
          # counters-based rate fallback
          last_counters: %{optional(String.t()) => %{rx_bytes: non_neg_integer(), tx_bytes: non_neg_integer()}},
          last_sample_ms: non_neg_integer(),
          rate_window_ms: pos_integer()
        }

  def start_link(config), do: GenServer.start_link(__MODULE__, config, name: __MODULE__)

  @impl true
  def init(config) do
    auth =
      Auth.new(
        username: config[:user],
        password: config[:pass],
        verify: config[:verify]
      )

    now_ms = System.monotonic_time(:millisecond)

    state = %{
      auth: auth,
      ip: config[:ip],
      scheme: config[:scheme] || :https,
      refresh_ms: config[:refresh_ms] || 500,
      system_resource: nil,
      interfaces: nil,
      dhcp_leases: nil,
      arp: nil,
      routes: nil,
      firewall: nil,
      nat: nil,
      nat_sessions: nil,
      errors: [],
      rate_map: %{},
      iface_cycle: [],
      cycle_pos: 0,
      last_counters: %{},
      last_sample_ms: now_ms,
      rate_window_ms: config[:rate_window_ms] || 1000
    }

    # Kick off periodic polls
    schedule(:tick_main, 0)
    schedule(:tick_dhcp, 0)
    schedule(:tick_arp, 0)
    schedule(:tick_routes, 0)
    schedule(:tick_fw, 0)
    schedule(:tick_nat, 0)
    schedule(:tick_conn, 0)
    {:ok, state}
  end

  def get_snapshot, do: GenServer.call(__MODULE__, :snapshot)
  def get_rates, do: GenServer.call(__MODULE__, :rates)
  def get_dhcp, do: GenServer.call(__MODULE__, :dhcp)
  def get_arp, do: GenServer.call(__MODULE__, :arp)
  def get_routes, do: GenServer.call(__MODULE__, :routes)
  def get_firewall, do: GenServer.call(__MODULE__, :firewall)
  def get_nat, do: GenServer.call(__MODULE__, :nat)
  def get_nat_sessions, do: GenServer.call(__MODULE__, :nat_sessions)
  def get_errors, do: GenServer.call(__MODULE__, :errors)

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, %{system_resource: state.system_resource, interfaces: state.interfaces, rate_map: state.rate_map}, state}
  end

  def handle_call(:dhcp, _from, state) do
    {:reply, state.dhcp_leases || [], state}
  end

  def handle_call(:arp, _from, state) do
    {:reply, state.arp || [], state}
  end

  def handle_call(:rates, _from, state) do
    {:reply, state.rate_map, state}
  end

  def handle_call(:routes, _from, state) do
    {:reply, state.routes || [], state}
  end

  def handle_call(:firewall, _from, state) do
    {:reply, state.firewall || [], state}
  end

  def handle_call(:nat, _from, state) do
    {:reply, state.nat || [], state}
  end

  def handle_call(:errors, _from, state) do
    {:reply, state.errors || [], state}
  end

  def handle_call(:nat_sessions, _from, state) do
    {:reply, state.nat_sessions || [], state}
  end

  @impl true
  def handle_info(:tick_main, state) do
    state = state |> fetch_main() |> sample_monitors_batch()
    schedule(:tick_main, state.refresh_ms)
    {:noreply, state}
  end

  def handle_info(:tick_dhcp, state) do
    state = fetch_dhcp(state)
    schedule(:tick_dhcp, max(state.refresh_ms * 4, 1000))
    {:noreply, state}
  end

  def handle_info(:tick_arp, state) do
    state = fetch_arp(state)
    schedule(:tick_arp, max(state.refresh_ms * 4, 1000))
    {:noreply, state}
  end

  def handle_info(:tick_routes, state) do
    state = fetch_routes(state)
    schedule(:tick_routes, max(state.refresh_ms * 6, 3000))
    {:noreply, state}
  end

  def handle_info(:tick_fw, state) do
    state = fetch_firewall(state)
    schedule(:tick_fw, max(state.refresh_ms * 8, 5000))
    {:noreply, state}
  end

  def handle_info(:tick_nat, state) do
    state = fetch_nat(state)
    schedule(:tick_nat, max(state.refresh_ms * 8, 5000))
    {:noreply, state}
  end

  def handle_info(:tick_conn, state) do
    state = fetch_nat_sessions(state)
    # Poll NAT sessions every 5 seconds to reduce router load
    schedule(:tick_conn, 5_000)
    {:noreply, state}
  end

  defp schedule(msg, ms) when is_integer(ms) and ms >= 0 do
    Process.send_after(self(), msg, ms)
  end

  defp fetch_main(state) do
    opts = [scheme: state.scheme]

    state =
      case MikrotikApi.system_resource(state.auth, state.ip, opts) do
        {:ok, data} -> state |> Map.put(:system_resource, data)
        {:error, err} ->
          Logger.error("system_resource failed: #{inspect(err)}")
          add_error(state, "system_resource", err)
      end

    state =
      case MikrotikApi.interface_list(state.auth, state.ip, opts) do
        {:ok, ifs} ->
          names =
            ifs
            |> Enum.map(&(&1["name"]))
            |> Enum.filter(&is_binary/1)

          state
          |> Map.put(:interfaces, ifs)
          |> Map.put(:iface_cycle, (if names == [], do: state.iface_cycle, else: names))
          |> Map.put(:cycle_pos, (if names == [], do: state.cycle_pos, else: 0))
          |> update_rates_from_counters(ifs)

        {:error, err} ->
          Logger.error("interface_list failed: #{inspect(err)}")
          add_error(state, "interface_list", err)
      end

    state
  end

  defp fetch_dhcp(state) do
    opts = [scheme: state.scheme]

    case MikrotikApi.dhcp_lease_list(state.auth, state.ip, opts) do
      {:ok, leases} -> Map.put(state, :dhcp_leases, leases)
      {:error, err} ->
        Logger.error("dhcp_lease_list failed: #{inspect(err)}")
        add_error(state, "dhcp_lease_list", err)
    end
  end

  defp fetch_arp(state) do
    opts = [scheme: state.scheme]

    case MikrotikApi.arp_list(state.auth, state.ip, opts) do
      {:ok, arp} -> Map.put(state, :arp, arp)
      {:error, err} ->
        Logger.error("arp_list failed: #{inspect(err)}")
        add_error(state, "arp_list", err)
    end
  end

  # Sample a small batch of interfaces with ethernet monitor to estimate live rates.
  defp sample_monitors_batch(%{interfaces: nil} = state), do: state
  defp sample_monitors_batch(%{iface_cycle: [], interfaces: _} = state), do: state
  defp sample_monitors_batch(state) do
    batch_size = 5
    names = state.iface_cycle
    total = length(names)
    pos = state.cycle_pos

    {batch, next_pos} = take_cycle(names, pos, batch_size)

    opts = [scheme: state.scheme]

    results =
      Task.Supervisor.async_stream_nolink(
        MikrotikTui.TaskSup,
        batch,
        fn name ->
          # First try ethernet-specific monitor; fall back to generic monitor-traffic if unavailable
          case MikrotikApi.interface_ethernet_monitor(state.auth, state.ip, name, Keyword.merge(opts, params: %{once: "true"})) do
            {:ok, m} -> {:ok, name, m}
            {:error, err_eth} ->
              Logger.debug(fn -> "ethernet_monitor #{name} failed: #{inspect(err_eth)}" end)
              # Fallback: /interface/monitor-traffic?interface=name&once=true
              case MikrotikApi.get(state.auth, state.ip, "/interface/monitor-traffic", Keyword.merge(opts, params: %{interface: name, once: "true"})) do
                {:ok, m2} -> {:ok, name, m2}
                {:error, err_fallback} ->
                  Logger.warning("monitor-traffic #{name} failed: #{inspect(err_fallback)}")
                  {:error, name, err_fallback}
              end
          end
        end,
        max_concurrency: 5,
        timeout: 2_000
      )
      |> Enum.map(fn
        {:ok, v} -> v
        {:exit, reason} -> {:error, :task_exit, reason}
      end)

    rate_map =
      Enum.reduce(results, state.rate_map, fn
        {:ok, name, m}, acc ->
          rx = parse_int(m["rx-bits-per-second"]) || 0
          tx = parse_int(m["tx-bits-per-second"]) || 0
          link = m["status"] || m["link-partner-state"]
          Map.put(acc, name, %{rx_bps: rx, tx_bps: tx, link: link})

        # Put the more specific tuple first to avoid clause overlap
        {:error, :task_exit, _reason}, acc ->
          acc

        {:error, _name, _err}, acc ->
          acc
      end)

    # Record any errors from the batch
    state =
      Enum.reduce(results, state, fn
        {:error, :task_exit, reason}, st -> add_error(st, "monitor-traffic task_exit", reason)
        {:error, name, err}, st -> add_error(st, "monitor-traffic #{name}", err)
        _ok, st -> st
      end)

    %{state | rate_map: rate_map, cycle_pos: next_pos || rem(pos + batch_size, total)}
  end

  defp take_cycle(list, pos, n) do
    total = length(list)
    cond do
      total == 0 -> {[], pos}
      n >= total -> {list, 0}
      true ->
        chunk1 = Enum.slice(list, pos, min(n, total - pos))
        need = n - length(chunk1)
        chunk2 = if need > 0, do: Enum.slice(list, 0, need), else: []
        next_pos = rem(pos + n, total)
        {chunk1 ++ chunk2, next_pos}
    end
  end

  defp parse_int(nil), do: nil
  defp parse_int(val) when is_integer(val), do: val
  defp parse_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {i, _} -> i
      :error -> nil
    end
  end

  # --- routes/firewall/nat ---

  defp fetch_routes(state) do
    opts = [scheme: state.scheme]

    case MikrotikApi.get(state.auth, state.ip, "/ip/route", opts) do
      {:ok, routes} -> Map.put(state, :routes, routes)
      {:error, err} ->
        Logger.error("ip/route failed: #{inspect(err)}")
        add_error(state, "ip/route", err)
    end
  end

  defp fetch_firewall(state) do
    opts = [scheme: state.scheme]

    case MikrotikApi.get(state.auth, state.ip, "/ip/firewall/filter", opts) do
      {:ok, fw} -> Map.put(state, :firewall, fw)
      {:error, err} ->
        Logger.error("ip/firewall/filter failed: #{inspect(err)}")
        add_error(state, "ip/firewall/filter", err)
    end
  end

  defp fetch_nat(state) do
    opts = [scheme: state.scheme]

    case MikrotikApi.get(state.auth, state.ip, "/ip/firewall/nat", opts) do
      {:ok, nat} -> Map.put(state, :nat, nat)
      {:error, err} ->
        Logger.error("ip/firewall/nat failed: #{inspect(err)}")
        add_error(state, "ip/firewall/nat", err)
    end
  end

  defp fetch_nat_sessions(state) do
    opts = [scheme: state.scheme]

    case MikrotikApi.get(state.auth, state.ip, "/ip/firewall/connection", opts) do
      {:ok, conns} -> Map.put(state, :nat_sessions, conns)
      {:error, err} ->
        Logger.error("ip/firewall/connection failed: #{inspect(err)}")
        add_error(state, "ip/firewall/connection", err)
    end
  end

  # --- error ring buffer ---

  defp add_error(state, source, err) do
    evt = %{
      at: System.system_time(:second),
      source: to_string(source),
      error: inspect(err)
    }

    errors = [evt | (state.errors || [])] |> Enum.take(100)
    %{state | errors: errors}
  end

  # --- counters-based rate fallback ---

  defp update_rates_from_counters(%{interfaces: nil} = state, _ifs), do: state
  defp update_rates_from_counters(state, ifs) do
    now_ms = System.monotonic_time(:millisecond)
    elapsed_ms = max(now_ms - (state.last_sample_ms || now_ms), 1)

    # Only recompute rates if at least rate_window_ms has elapsed; otherwise, keep previous rates
    if elapsed_ms < (state.rate_window_ms || 1000) do
      state
    else
      {rate_updates, new_counters} =
        ifs
        |> Enum.reduce({state.rate_map, state.last_counters}, fn ifc, {acc_rates, acc_cnt} ->
        name = ifc["name"]

        with true <- is_binary(name),
             rx0 when is_integer(rx0) <- get_counter(ifc, ["rx-byte", "rx-bytes", "rx-bytes64", "rx", "rx-bytes-per-second"], :bytes),
             tx0 when is_integer(tx0) <- get_counter(ifc, ["tx-byte", "tx-bytes", "tx-bytes64", "tx", "tx-bytes-per-second"], :bytes) do
          prev = Map.get(acc_cnt, name, %{rx_bytes: rx0, tx_bytes: tx0})

          rx_bytes = normalize_bytes(rx0)
          tx_bytes = normalize_bytes(tx0)

          drx = max(rx_bytes - prev.rx_bytes, 0)
          dtx = max(tx_bytes - prev.tx_bytes, 0)

          # Convert bytes over elapsed_ms to bits per second
          rx_bps_raw = div(drx * 8 * 1000, elapsed_ms)
          tx_bps_raw = div(dtx * 8 * 1000, elapsed_ms)

          # Smooth with previous value to reduce jitter (70% new, 30% old)
          prev = Map.get(acc_rates, name, %{rx_bps: 0, tx_bps: 0, link: nil})
          rx_bps = smooth(prev.rx_bps, rx_bps_raw)
          tx_bps = smooth(prev.tx_bps, tx_bps_raw)

          link = infer_link(ifc)

          {Map.put(acc_rates, name, %{rx_bps: rx_bps, tx_bps: tx_bps, link: link}),
           Map.put(acc_cnt, name, %{rx_bytes: rx_bytes, tx_bytes: tx_bytes})}
        else
          _ -> {acc_rates, acc_cnt}
        end
      end)

    state
    |> Map.put(:rate_map, rate_updates)
    |> Map.put(:last_counters, new_counters)
    |> Map.put(:last_sample_ms, now_ms)
    end
  end

  defp get_counter(map, keys, unit) do
    keys
    |> Enum.find_value(fn k ->
      v = Map.get(map, k)
      case {unit, v} do
        {:bytes, val} when is_integer(val) -> val
        {:bytes, val} when is_binary(val) -> parse_int(val)
        # some firmwares may already supply per-second metrics; convert roughly back to bytes for consistency
        {:per_sec, val} when is_integer(val) -> val
        _ -> nil
      end
    end)
  end

  defp normalize_bytes(val) when is_integer(val) and val >= 0, do: val
  defp normalize_bytes(_), do: 0

  defp smooth(prev, cur) when is_integer(prev) and is_integer(cur) do
    # 0.7*cur + 0.3*prev, integer math
    div(cur * 7 + prev * 3, 10)
  end

  defp infer_link(map) do
    cond do
      Map.get(map, "running") in [true, "true"] -> "running"
      Map.get(map, "status") -> Map.get(map, "status")
      true -> nil
    end
  end
end
