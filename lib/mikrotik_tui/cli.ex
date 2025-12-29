defmodule MikrotikTui.CLI do
  @moduledoc """
  Escript entry point for MikrotikTui.
  """

  def main(argv) do
    # Store argv so Application.start can access it via System.argv()
    System.argv(argv)

    # Ensure kernel is fully started for network in escript
    {:ok, _} = Application.ensure_all_started(:kernel)

    # Ensure network applications are started (required for httpc in escript)
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    # Start the application
    {:ok, _} = Application.ensure_all_started(:mikrotik_tui)

    # Keep the escript running until the app exits
    receive do
      :stop -> :ok
    end
  end
end
