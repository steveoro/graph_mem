# Load the full Rails environment to access models, DB, Redis, etc.
require_relative "config/environment"

# No need to set a custom endpoint path. The MCP endpoint is always served at root ("/")
# when using ActionMCP::Engine directly.
run ActionMCP::Engine
