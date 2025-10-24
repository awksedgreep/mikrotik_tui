defmodule MikrotikTui.Application do
  @moduledoc false
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    # Read configuration/ENV for router target
    config = load_config()

    children = [
      {MikrotikTui.DataCache, config},
      {Task.Supervisor, name: MikrotikTui.TaskSup},
      {MikrotikTui.UI, config}
    ]

    Logger.info("mikrotik_tui starting")

    opts = [strategy: :one_for_one, name: MikrotikTui.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp load_config do
    {cli, _rest, _invalid} =
      OptionParser.parse(System.argv(),
        switches: [
          ip: :string,
          user: :string,
          pass: :string,
          scheme: :string,
          verify: :string,
          refresh_ms: :integer,
          tab: :string
        ],
        aliases: [i: :ip, u: :user, p: :pass, s: :scheme, v: :verify, r: :refresh_ms, t: :tab]
      )

    env = %{
      ip: System.get_env("MIKROTIK_IP"),
      user: System.get_env("MIKROTIK_USER"),
      pass: System.get_env("MIKROTIK_PASS"),
      scheme: scheme_env(System.get_env("MIKROTIK_SCHEME")),
      verify: verify_env(System.get_env("MIKROTIK_VERIFY")),
      refresh_ms: refresh_env(System.get_env("MIKROTIK_REFRESH_MS")),
      tab: tab_env(System.get_env("MIKROTIK_TAB"))
    }

    defaults = %{
      ip: "127.0.0.1",
      user: "admin",
      pass: "",
      scheme: :http,
      verify: :verify_peer,
      refresh_ms: 1000
    }

    defaults
    |> Map.merge(Map.new(Enum.reject(env, fn {_k, v} -> is_nil(v) end)))
    |> Map.merge(normalize_cli(cli))
  end

  defp normalize_cli(cli) do
    %{}
    |> put_if(cli, :ip)
    |> put_if(cli, :user)
    |> put_if(cli, :pass)
    |> put_if(cli, :refresh_ms)
    |> then(fn acc ->
      acc
      |> Map.merge(if cli[:scheme], do: %{scheme: scheme_env(cli[:scheme])}, else: %{})
      |> Map.merge(if cli[:verify], do: %{verify: verify_env(cli[:verify])}, else: %{})
      |> Map.merge(if cli[:tab], do: %{tab: tab_env(cli[:tab])}, else: %{})
    end)
  end

  defp put_if(acc, cli, key) do
    if cli[key] do
      Map.put(acc, key, cli[key])
    else
      acc
    end
  end

  defp scheme_env("https"), do: :https
  defp scheme_env("http"), do: :http
  defp scheme_env(_), do: :https

  defp verify_env("none"), do: :verify_none
  defp verify_env(_), do: :verify_peer

  defp refresh_env(val) do
    case Integer.parse(val || "500") do
      {ms, _} when ms > 0 -> ms
      _ -> 500
    end
  end

  defp tab_env(nil), do: nil
  defp tab_env(val) when is_binary(val) do
    case String.downcase(val) do
      "main" -> :main
      "dhcp" -> :dhcp
      "arp" -> :arp
      _ -> nil
    end
  end
end
