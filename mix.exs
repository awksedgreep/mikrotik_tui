defmodule MikrotikTui.MixProject do
  use Mix.Project

  def project do
    [
      app: :mikrotik_tui,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
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
      {:mikrotik_api, path: "../mikrotik_api"},
      {:logger_file_backend, "~> 0.0.13"}
    ]
  end
end
