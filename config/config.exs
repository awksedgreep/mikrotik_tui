import Config

# Disable default console handler to avoid polluting the TUI
config :logger, :default_handler, false
config :logger, level: :info
