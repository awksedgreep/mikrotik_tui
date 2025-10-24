import Config

# Ensure log directory exists for file backend
File.mkdir_p!("log")

# Configure Logger to write only to file (avoid polluting the TUI console)
config :logger,
  backends: [{LoggerFileBackend, :file_log}],
  level: :info

config :logger, :file_log,
  path: "log/mikrotik_tui.log",
  level: :info
