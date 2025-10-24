defmodule MikrotikTui.UI do
  @moduledoc """
  Termite-based UI loop with tabs and periodic redraws.
  """
  use GenServer
  require Logger
  alias Termite.Terminal
  alias Termite.Screen

  @tabs [:int, :errors, :leases, :routes, :arp, :firewall, :nat, :nat_sessions]

  def start_link(config), do: GenServer.start_link(__MODULE__, config, name: __MODULE__)

  @impl true
  def init(config) do
    term0 = Terminal.start()
    term1 = Screen.alt_screen(term0)
    term2 = Screen.hide_cursor(term1)

    size = Map.get(term2, :size, %{width: 0, height: 0})

    input_port = open_stdin_port()

    state = %{
      term: term2,
      width: size.width,
      height: size.height,
      active: tab_from_config(config[:tab]) || :int,
      refresh_ms: ui_refresh_ms(config),
      paused: false,
      input_port: input_port,
      input_buf: <<>>
    }

    # Log reader ref and pid for diagnostics
    Logger.info(fn -> "ui_init reader=#{inspect(state.term.reader)} pid=#{inspect(self())}" end)

    # Clear once on init to avoid initial artifacts
    Screen.clear_screen(state.term)
    redraw(state)
    schedule_tick(state.refresh_ms)
    schedule_input_tick()
    {:ok, state}
  end

  defp schedule_tick(ms), do: Process.send_after(self(), :tick, ms)
  defp schedule_input_tick(), do: Process.send_after(self(), :input_tick, 50)

  defp ui_refresh_ms(config) do
    refresh = config[:refresh_ms] || 1000
    window = config[:rate_window_ms] || 1000
    max(refresh, window)
  end

  defp tab_from_config(:int), do: :int
  defp tab_from_config(:errors), do: :errors
  defp tab_from_config(:leases), do: :leases
  defp tab_from_config(:routes), do: :routes
  defp tab_from_config(:arp), do: :arp
  defp tab_from_config(:firewall), do: :firewall
  defp tab_from_config(:nat), do: :nat
  # Back-compat for older flags
  defp tab_from_config(:main), do: :int
  defp tab_from_config(:dhcp), do: :leases
  defp tab_from_config(_), do: nil

  # Colors to match footer palette
  defp tab_color(:int), do: 2        # green
  defp tab_color(:errors), do: 1     # red
  defp tab_color(:leases), do: 3     # yellow
  defp tab_color(:routes), do: 5     # magenta
  defp tab_color(:arp), do: 4        # blue
  defp tab_color(:firewall), do: 6   # cyan
  defp tab_color(:nat), do: 7        # gray/white
  defp tab_color(:nat_sessions), do: 7 # gray/white

  @impl true
  def handle_info(:tick, %{paused: true} = state) do
    # Drain any pending input quickly, then reschedule
    st = drain_poll(state)
    schedule_tick(st.refresh_ms)
    {:noreply, st}
  end

  def handle_info(:tick, state) do
    st = drain_poll(state)
    redraw(st)
    schedule_tick(st.refresh_ms)
    {:noreply, st}
  end

  # High-frequency input tick to make keys responsive
  def handle_info(:input_tick, state) do
    st = drain_poll(state)
    schedule_input_tick()
    {:noreply, st}
  end

  # stdin port data (raw bytes)
  def handle_info({port, {:data, data}}, %{input_port: port} = state) when is_binary(data) do
    {new_state, leftover} = consume_input(state, state.input_buf <> data)
    {:noreply, %{new_state | input_buf: leftover}}
  end

  # stdin port closed
  def handle_info({port, :eof}, %{input_port: port} = state), do: {:noreply, state}
  def handle_info({:EXIT, port, _reason}, %{input_port: port} = state), do: {:noreply, state}


  # --- input polling (Termite-aligned) ---
  defp drain_poll(state) do
    case Termite.Terminal.poll(state.term, 0) do
      :timeout -> state
      {:resize, w, h} ->
        state
        |> Map.put(:width, w)
        |> Map.put(:height, h)
        |> then(&Screen.clear_screen(&1.term) |> then(fn _ -> &1 end))
        |> redraw()
        |> drain_poll()

      {:key, :left} -> %{state | active: prev_tab(state.active)} |> redraw() |> drain_poll()
      {:key, :right} -> %{state | active: next_tab(state.active)} |> redraw() |> drain_poll()
      {:key, ?1} -> %{state | active: :int} |> redraw() |> drain_poll()
      {:key, ?2} -> %{state | active: :errors} |> redraw() |> drain_poll()
      {:key, ?3} -> %{state | active: :leases} |> redraw() |> drain_poll()
      {:key, ?4} -> %{state | active: :routes} |> redraw() |> drain_poll()
      {:key, ?5} -> %{state | active: :arp} |> redraw() |> drain_poll()
      {:key, ?6} -> %{state | active: :firewall} |> redraw() |> drain_poll()
      {:key, ?7} -> %{state | active: :nat} |> redraw() |> drain_poll()
      {:key, ?8} -> %{state | active: :nat_sessions} |> redraw() |> drain_poll()
      {:key, ?p} -> %{state | paused: !state.paused} |> redraw() |> drain_poll()
      {:key, ?q} -> cleanup(state); System.halt(0); state
      _other -> drain_poll(state)
    end
  end

  defp prev_tab(tab) do
    idx = Enum.find_index(@tabs, &(&1 == tab)) || 0
    Enum.at(@tabs, rem(idx - 1 + length(@tabs), length(@tabs)))
  end

  defp next_tab(tab) do
    idx = Enum.find_index(@tabs, &(&1 == tab)) || 0
    Enum.at(@tabs, rem(idx + 1, length(@tabs)))
  end

  defp redraw(state) do
    # Avoid clearing every frame; just reposition and overwrite to reduce flicker
    term =
      state.term
      |> Screen.cursor_position(1, 1)
      |> Termite.Terminal.write(render(state))
      |> Termite.Terminal.write("\e[J")

    # Footer banner with key instructions at the bottom row
    term =
      term
      |> Screen.cursor_position(1, max(state.height, 1))
      |> Termite.Terminal.write(eol())
      |> Termite.Terminal.write(render_footer(state))

    %{state | term: term}
  end

  defp render(state) do
    [render_header(state), "\n", render_tab_bar(state.active), "\n", render_body(state)]
    |> IO.iodata_to_binary()
  end

  defp render_header(state) do
    snap = MikrotikTui.DataCache.get_snapshot()
    sys = snap.system_resource || %{}
    width = state.width || 0

    model = safe_kv(sys, "board-name")
    ros = safe_kv(sys, "version")
    platform = safe_kv(sys, "platform")
    free = int_kv(sys, "free-memory")
    total = int_kv(sys, "total-memory")
    cpu = safe_kv(sys, "cpu-load")

    seg_model =
      Termite.Style.foreground(%Termite.Style{}, 6)
      |> Termite.Style.bold()
      |> Termite.Style.render_to_string("Model: " <> model)

    seg_ros =
      Termite.Style.foreground(%Termite.Style{}, 3)
      |> Termite.Style.bold()
      |> Termite.Style.render_to_string("ROS: " <> ros)

    seg_platform =
      Termite.Style.foreground(%Termite.Style{}, 5)
      |> Termite.Style.render_to_string("Platform: " <> platform)

    used =
      case {free, total} do
        {f, t} when is_integer(f) and is_integer(t) and t >= f -> t - f
        _ -> nil
      end

    seg_mem =
      Termite.Style.foreground(%Termite.Style{}, 4)
      |> Termite.Style.render_to_string("Mem: " <> human_bytes(used) <> "/" <> human_bytes(total))

    seg_cpu =
      Termite.Style.foreground(%Termite.Style{}, 1)
      |> Termite.Style.render_to_string("CPU: " <> cpu <> "%")

    text = Enum.join([seg_model, seg_ros, seg_platform, seg_mem, seg_cpu], "  |  ")

    if width > 0, do: fit_to_width(text, width), else: text
  end

  defp render_footer(state) do
    # Build colored segments using Termite.Style
    seg_key = Termite.Style.foreground(%Termite.Style{}, 6) |> Termite.Style.bold() |> Termite.Style.render_to_string("Keys:")
    seg_int = Termite.Style.foreground(%Termite.Style{}, 2) |> Termite.Style.bold() |> Termite.Style.render_to_string("1 Int")
    seg_err = Termite.Style.foreground(%Termite.Style{}, 1) |> Termite.Style.bold() |> Termite.Style.render_to_string("2 Errors")
    seg_lease = Termite.Style.foreground(%Termite.Style{}, 3) |> Termite.Style.bold() |> Termite.Style.render_to_string("3 Leases")
    seg_routes = Termite.Style.foreground(%Termite.Style{}, 5) |> Termite.Style.render_to_string("4 Routes")
    seg_arp = Termite.Style.foreground(%Termite.Style{}, 4) |> Termite.Style.bold() |> Termite.Style.render_to_string("5 ARP")
    seg_fw = Termite.Style.foreground(%Termite.Style{}, 6) |> Termite.Style.render_to_string("6 Firewall")
    seg_nat = Termite.Style.foreground(%Termite.Style{}, 7) |> Termite.Style.render_to_string("7 NAT")
    seg_nat_sess = Termite.Style.foreground(%Termite.Style{}, 7) |> Termite.Style.render_to_string("8 NAT Sessions")
    seg_arrows = Termite.Style.foreground(%Termite.Style{}, 5) |> Termite.Style.render_to_string("←/→ switch")
    seg_pause = Termite.Style.foreground(%Termite.Style{}, 7) |> Termite.Style.render_to_string("p Pause")
    seg_quit = Termite.Style.foreground(%Termite.Style{}, 1) |> Termite.Style.bold() |> Termite.Style.render_to_string("q Quit")

    text = Enum.join([seg_key, seg_int, seg_err, seg_lease, seg_routes, seg_arp, seg_fw, seg_nat, seg_nat_sess, seg_arrows, seg_pause, seg_quit], "  |  ")
    width = state.width || 0

    cond do
      width <= 0 -> text
      true -> fit_to_width(text, width)
    end
  end

  defp fit_to_width(text, width) when is_integer(width) and width > 0 do
    s = to_string(text)
    s_trunc = String.slice(s, 0, width)
    s_trunc <> String.duplicate(" ", max(width - String.length(s_trunc), 0))
  end

  defp render_tab_bar(active) do
    tabs = [
      {"Int", :int},
      {"Errors", :errors},
      {"Leases", :leases},
      {"Routes", :routes},
      {"ARP", :arp},
      {"Firewall", :firewall},
      {"NAT", :nat},
      {"NAT Sessions", :nat_sessions}
    ]

    bar =
      tabs
      |> Enum.map(fn {label, key} ->
        color = tab_color(key)
        style = Termite.Style.foreground(%Termite.Style{}, color) |> Termite.Style.bold()
        text = if key == active, do: "[" <> label <> "]", else: label
        Termite.Style.render_to_string(style, text)
      end)
      |> Enum.join("  ")

    bar <> eol()
  end

  defp render_body(%{active: :int}) do
    snap = MikrotikTui.DataCache.get_snapshot()
    ifs = snap.interfaces || []

    rates = MikrotikTui.DataCache.get_rates()

    header = [
      header_line(["  ", lpad("Interface", 12), "  ", lpad("rx", 15), "  ", lpad("tx", 15), "  ", lpad("link", 16)]),
      eol(), "\n"
    ]

    iface_lines =
      ifs
      |> Enum.map(fn e ->
        name = e["name"] || "?"
        rate = Map.get(rates, name, %{rx_bps: 0, tx_bps: 0, link: nil})
        total = rate.rx_bps + rate.tx_bps
        {total, name, rate}
      end)
      |> Enum.sort_by(fn {total, _name, _rate} -> -total end)
      |> Enum.take(10)
      |> Enum.map(fn {_total, name, rate} ->
        link = if rate.link, do: to_string(rate.link), else: ""
        [
          "- ", lpad(name, 12),
          "  ", rpad(human_bps(rate.rx_bps), 15),
          "  ", rpad(human_bps(rate.tx_bps), 15),
          "  ", lpad(link, 16),
          eol(), "\n"
        ]
      end)

    [header | iface_lines] |> IO.iodata_to_binary()
  end

  defp render_body(%{active: :errors} = state) do
    snap = MikrotikTui.DataCache.get_snapshot()
    ifs = snap.interfaces || []

    header = [header_line(:io_lib.format("~-12s  ~-8s  ~-8s  ~-8s  ~-8s  ~-8s  ~-8s", [
      "Interface", "RX-err", "TX-err", "RX-drop", "TX-drop", "FCS", "Align"
    ])), eol(), "\n"]

    max_rows = max((state.height || 0) - 3, 1)

    rows =
      ifs
      |> Enum.map(fn e ->
        name = e["name"] || "?"
        rx_err = get_first_int(e, ["rx-error", "rx-errors", "receive-error", "receive-errors"]) || 0
        tx_err = get_first_int(e, ["tx-error", "tx-errors", "transmit-error", "transmit-errors"]) || 0
        rx_drop = get_first_int(e, ["rx-drop", "rx-drops", "receive-drop", "receive-drops"]) || 0
        tx_drop = get_first_int(e, ["tx-drop", "tx-drops", "transmit-drop", "transmit-drops"]) || 0
        fcs = get_first_int(e, ["fcs-error", "fcs-errors"]) || 0
        align = get_first_int(e, ["align-error", "alignment-error", "alignment-errors"]) || 0
        total = rx_err + tx_err + rx_drop + tx_drop + fcs + align
        {total, name, rx_err, tx_err, rx_drop, tx_drop, fcs, align}
      end)
      |> Enum.sort_by(fn {total, _n, _a, _b, _c, _d, _e, _f} -> -total end)
      |> Enum.take(max_rows)
      |> Enum.map(fn {_total, name, rx_err, tx_err, rx_drop, tx_drop, fcs, align} ->
        row = :io_lib.format("~-12s  ~8B  ~8B  ~8B  ~8B  ~8B  ~8B", [
          name, rx_err, tx_err, rx_drop, tx_drop, fcs, align
        ])
        [row, eol(), "\n"]
      end)

    [header | rows] |> IO.iodata_to_binary()
  end

  defp render_body(%{active: :leases}) do
    leases = MikrotikTui.DataCache.get_dhcp()

    header = [header_line("Address             MAC                  Status       Hostname"), eol(), "\n"]

    rows =
      leases
      |> Enum.map(fn e ->
        row = :io_lib.format("~s  ~-18s  ~-12s  ~s", [
          pad(e["address"], 18),
          pad(e["mac-address"], 18),
          pad(e["status"], 12),
          pad(e["host-name"], 20)
        ])
        [row, eol(), "\n"]
      end)

    [header | rows] |> IO.iodata_to_binary()
  end

  defp render_body(%{active: :routes}) do
    routes = MikrotikTui.DataCache.get_routes()

    header = [header_line(:io_lib.format("~-4s  ~-20s  ~-20s  ~-10s  ~-8s", ["Dst", "Gateway", "PrefSrc", "Distance", "Scope"])), eol(), "\n"]

    rows =
      routes
      |> Enum.map(fn r ->
        row = :io_lib.format("~-4s  ~-20s  ~-20s  ~-10s  ~-8s", [
          flag(r),
          pad(r["gateway"], 20),
          pad(r["pref-src"], 20),
          pad(r["distance"], 10),
          pad(r["scope"], 8)
        ])
        [row, eol(), "\n"]
      end)

    [header | rows] |> IO.iodata_to_binary()
  end

  defp render_body(%{active: :firewall}) do
    rules = MikrotikTui.DataCache.get_firewall()

    header = [header_line(:io_lib.format("~-4s  ~-6s  ~-10s  ~-10s  ~-10s  ~-6s  ~-20s", ["#", "Chain", "Src", "Dst", "Proto", "Action", "Comment"])), eol(), "\n"]

    rows =
      rules
      |> Enum.with_index(1)
      |> Enum.map(fn {r, i} ->
        row = :io_lib.format("~-4B  ~-6s  ~-10s  ~-10s  ~-10s  ~-6s  ~-20s", [
          i,
          pad(r["chain"], 6),
          pad(r["src-address"], 10),
          pad(r["dst-address"], 10),
          pad(r["protocol"], 10),
          pad(r["action"], 6),
          pad(r["comment"], 20)
        ])
        [row, eol(), "\n"]
      end)

    [header | rows] |> IO.iodata_to_binary()
  end

  defp render_body(%{active: :nat}) do
    rules = MikrotikTui.DataCache.get_nat()

    header = [header_line(:io_lib.format("~-4s  ~-6s  ~-14s  ~-14s  ~-10s  ~-6s  ~-20s", ["#", "Chain", "SrcAddr", "DstAddr", "Proto", "Action", "Comment"])), eol(), "\n"]

    rows =
      rules
      |> Enum.with_index(1)
      |> Enum.map(fn {r, i} ->
        row = :io_lib.format("~-4B  ~-6s  ~-14s  ~-14s  ~-10s  ~-6s  ~-20s", [
          i,
          pad(r["chain"], 6),
          pad(r["src-address"], 14),
          pad(r["dst-address"], 14),
          pad(r["protocol"], 10),
          pad(r["action"], 6),
          pad(r["comment"], 20)
        ])
        [row, eol(), "\n"]
      end)

    [header | rows] |> IO.iodata_to_binary()
  end

  defp render_body(%{active: :nat_sessions} = state) do
    conns = MikrotikTui.DataCache.get_nat_sessions()

    header = [header_line(:io_lib.format("~-5s  ~-6s  ~-21s  ~-21s  ~-6s  ~-8s  ~-8s", ["#", "Proto", "Src", "Dst", "State", "Timeout", "Orig"])), eol(), "\n"]

    max_rows = max((state.height || 0) - 4, 1)

    rows =
      conns
      |> Enum.with_index(1)
      |> Enum.take(max_rows)
      |> Enum.map(fn {c, i} ->
        src = join_addr_port(c["src-address"], c["src-port"]) || join_addr_port(c["src-address"], c["orig-src-port"]) || ""
        dst = join_addr_port(c["dst-address"], c["dst-port"]) || join_addr_port(c["dst-address"], c["orig-dst-port"]) || ""
        row = :io_lib.format("~-5B  ~-6s  ~-21s  ~-21s  ~-6s  ~-8s  ~-8s", [
          i,
          pad(c["protocol"], 6),
          pad(src, 21),
          pad(dst, 21),
          pad(c["tcp-state"] || c["state"], 6),
          pad(c["timeout"], 8),
          pad(c["orig-bytes"], 8)
        ])
        [row, eol(), "\n"]
      end)

    [header | rows] |> IO.iodata_to_binary()
  end

  defp render_body(%{active: :arp} = state) do
    entries = MikrotikTui.DataCache.get_arp()

    header = [header_line(:io_lib.format("~-18s  ~-18s  ~-12s", ["Address", "MAC", "Interface"])), eol(), "\n"]

    max_rows = max((state.height || 0) - 4, 1)

    rows =
      entries
      |> Enum.take(max_rows)
      |> Enum.map(fn e ->
        row = :io_lib.format("~-18s  ~-18s  ~-12s", [
          pad(e["address"], 18),
          pad(e["mac-address"], 18),
          pad(e["interface"], 12)
        ])
        [row, eol(), "\n"]
      end)

    [header | rows] |> IO.iodata_to_binary()
  end

  defp render_body(%{active: other}) do
    ["Tab ", to_string(other), " not implemented", eol(), "\n"] |> IO.iodata_to_binary()
  end

  defp pad(nil, _), do: ""
  defp pad(value, _), do: to_string(value)

  defp get_first_int(map, keys) do
    keys
    |> Enum.find_value(fn k ->
      v = Map.get(map || %{}, k)
      cond do
        is_integer(v) -> v
        is_binary(v) ->
          case Integer.parse(v) do
            {i, _} -> i
            :error -> nil
          end
        true -> nil
      end
    end)
  end

  defp flag(route) do
    dst = route["dst-address"] || route["dst"] || ""
    pref = if route["active"] in [true, "true"], do: "A", else: " "
    pref <> (if String.starts_with?(to_string(dst), "0.0.0.0"), do: "*", else: " ")
  end

  defp lpad(value, width) do
    s = to_string(value)
    s_trunc = String.slice(s, 0, max(width, 0))
    s_trunc <> String.duplicate(" ", max(width - String.length(s_trunc), 0))
  end

  defp rpad(value, width) do
    s = to_string(value)
    s_trunc = String.slice(s, 0, max(width, 0))
    String.duplicate(" ", max(width - String.length(s_trunc), 0)) <> s_trunc
  end

  defp eol, do: "\e[K"

  defp header_line(iodata) do
    style = Termite.Style.foreground(%Termite.Style{}, 6) |> Termite.Style.bold()
    Termite.Style.render_to_string(style, IO.iodata_to_binary(iodata))
  end

  defp human_bps(bps) when is_integer(bps) do
    cond do
      bps >= 1_000_000_000 -> :io_lib.format("~.1f Gbps", [bps / 1_000_000_000.0]) |> IO.iodata_to_binary()
      bps >= 1_000_000 -> :io_lib.format("~.1f Mbps", [bps / 1_000_000.0]) |> IO.iodata_to_binary()
      bps >= 1_000 -> :io_lib.format("~.1f Kbps", [bps / 1_000.0]) |> IO.iodata_to_binary()
      true -> to_string(bps) <> " bps"
    end
  end

  defp human_bps(_), do: "0 bps"

  defp join_addr_port(nil, _), do: nil
  defp join_addr_port(addr, nil), do: to_string(addr)
  defp join_addr_port(addr, port), do: to_string(addr) <> ":" <> to_string(port)

  defp safe_kv(map, key), do: to_string(Map.get(map || %{}, key, "?"))

  defp int_kv(map, key) do
    case Map.get(map || %{}, key) do
      i when is_integer(i) -> i
      b when is_binary(b) ->
        case Integer.parse(b) do
          {n, _} -> n
          :error -> nil
        end
      _ -> nil
    end
  end

  defp human_bytes(nil), do: "?"
  defp human_bytes(bytes) when is_integer(bytes) and bytes >= 0 do
    cond do
      bytes >= 1_073_741_824 -> :io_lib.format("~.1f GiB", [bytes / 1_073_741_824.0]) |> IO.iodata_to_binary()
      bytes >= 1_048_576 -> :io_lib.format("~.1f MiB", [bytes / 1_048_576.0]) |> IO.iodata_to_binary()
      bytes >= 1_024 -> :io_lib.format("~.1f KiB", [bytes / 1_024.0]) |> IO.iodata_to_binary()
      true -> to_string(bytes) <> " B"
    end
  end
  defp human_bytes(_), do: "?"

  defp cleanup(state) do
    state.term
    |> Screen.show_cursor()
    |> Screen.exit_alt_screen()
    set_stdin_sane()
    :ok
  end

  # --- stdin port (raw) ---
  defp open_stdin_port do
    set_stdin_raw()
    # Open fd 0 as a Port to receive raw bytes
    Port.open({:fd, 0, 0}, [:binary, :stream, :eof])
  end

  defp set_stdin_raw do
    sh = System.find_executable("sh") || "/bin/sh"
    _ = System.cmd(sh, ["-c", "stty raw -echo < /dev/tty 2>/dev/null || stty raw -echo"], stderr_to_stdout: true)
    :ok
  end

  defp set_stdin_sane do
    sh = System.find_executable("sh") || "/bin/sh"
    _ = System.cmd(sh, ["-c", "stty sane < /dev/tty 2>/dev/null || stty sane"], stderr_to_stdout: true)
    :ok
  end

  # Parse raw input bytes, return {state, leftover_buf}
  defp consume_input(state, <<27, ?[, ?D, rest::binary>>), do: {%{state | active: prev_tab(state.active)} |> redraw(), rest}
  defp consume_input(state, <<27, ?[, ?C, rest::binary>>), do: {%{state | active: next_tab(state.active)} |> redraw(), rest}
  defp consume_input(state, <<27, ?O, ?D, rest::binary>>), do: {%{state | active: prev_tab(state.active)} |> redraw(), rest}
  defp consume_input(state, <<27, ?O, ?C, rest::binary>>), do: {%{state | active: next_tab(state.active)} |> redraw(), rest}
  defp consume_input(state, <<?1, rest::binary>>), do: {%{state | active: :int} |> redraw(), rest}
  defp consume_input(state, <<?2, rest::binary>>), do: {%{state | active: :errors} |> redraw(), rest}
  defp consume_input(state, <<?3, rest::binary>>), do: {%{state | active: :leases} |> redraw(), rest}
  defp consume_input(state, <<?4, rest::binary>>), do: {%{state | active: :routes} |> redraw(), rest}
  defp consume_input(state, <<?5, rest::binary>>), do: {%{state | active: :arp} |> redraw(), rest}
  defp consume_input(state, <<?6, rest::binary>>), do: {%{state | active: :firewall} |> redraw(), rest}
  defp consume_input(state, <<?7, rest::binary>>), do: {%{state | active: :nat} |> redraw(), rest}
  defp consume_input(state, <<?8, rest::binary>>), do: {%{state | active: :nat_sessions} |> redraw(), rest}
  defp consume_input(state, <<?p, rest::binary>>), do: {%{state | paused: !state.paused} |> redraw(), rest}
  defp consume_input(state, <<?q, rest::binary>>) do
    cleanup(state)
    System.halt(0)
    {state, rest}
  end
  # Incomplete ESC sequence: wait for more
  defp consume_input(state, <<27>> = buf), do: {state, buf}
  defp consume_input(state, <<27, ?[>> = buf), do: {state, buf}
  defp consume_input(state, <<27, ?O>> = buf), do: {state, buf}
  # Unknown byte: drop and continue
  defp consume_input(state, <<_x, rest::binary>>), do: consume_input(state, rest)
  # Empty buffer
  defp consume_input(state, <<>>), do: {state, <<>>}
end
