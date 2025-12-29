defmodule MikrotikTui.MixProject do
  use Mix.Project

  def project do
    [
      app: :mikrotik_tui,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: escript()
    ]
  end

  defp escript do
    [
      main_module: MikrotikTui.CLI,
      name: "mikrotik_tui",
      emu_args: ~c"-proto_dist inet_tcp"
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :inets, :ssl],
      mod: {MikrotikTui.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:termite, "~> 0.3"},
      {:mikrotik_api, "~> 0.3.3"}
    ]
  end
end
