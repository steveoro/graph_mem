# frozen_string_literal: true

# COMMENTED OUT - Using official MCP Ruby SDK instead of FastMCP

# require_relative "../../lib/graph_mem/version" # Ensure GraphMem::VERSION is loaded
# require "fast_mcp"
#
# # Toggle this to enable/disable debug output
# debug_mode = false
#
# # Clear any existing FastMcp server instance if Rails reloads initializers
# # This helps prevent issues with stale server instances in development.
# if Rails.env.development? && defined?(FastMcp.server) && FastMcp.server
#   puts "[DEBUG] FastMcp Initializer: Clearing existing FastMcp.server instance" if debug_mode
#   FastMcp.server = nil
# end
#
# puts "[DEBUG] FastMcp Initializer: Starting setup..." if debug_mode
#
# # Configure FastMcp logger
# fast_mcp_logger = Logger.new(STDOUT)
# fast_mcp_logger.level = Logger::DEBUG # Or your preferred level (INFO, WARN, ERROR)
#
# # Use FastMcp.mount_in_rails to set up and mount the server
# FastMcp.mount_in_rails(
#   Rails.application,
#   name: "graph-mem",
#   version: GraphMem::VERSION.to_s,
#   logger: fast_mcp_logger,
#   # path_prefix: "/mcp", # This is the default in mount_in_rails
#   allowed_origins: FastMcp.default_rails_allowed_origins(Rails.application) + [
#     "127.0.0.1",
#     %r{\Ahttp://127\.0\.0\.1(:\d+)?\z}, # Matches http://127.0.0.1 with any port
#     %r{\Ahttp://localhost(:\d+)?\z}     # Matches http://localhost with any port
#   ]
# ) do |server| # server here is the FastMcp::Server instance
#   puts "[DEBUG] FastMcp Initializer (mount_in_rails block): Configuring FastMcp::Server instance (name: #{server.name}, version: #{server.version})" if debug_mode
#
#   # Dynamically load and register tools from app/tools
#   tools_dir = Rails.root.join("app", "tools")
#   if Dir.exist?(tools_dir)
#     Dir[tools_dir.join("**", "*_tool.rb")].each do |file|
#       require_dependency file # Use require_dependency for Rails development auto-reloading
#       tool_class_name = File.basename(file, ".rb").camelize
#       begin
#         tool_class = tool_class_name.safe_constantize
#         # Register all descendents, except the base class ApplicationTool
#         if tool_class && tool_class != ApplicationTool && tool_class < FastMcp::Tool
#           server.register_tool(tool_class) # Register the class
#           puts "[DEBUG] FastMcp Initializer (mount_in_rails block): Registered tool: #{tool_class.tool_name}" if debug_mode
#         end
#       rescue NameError => e
#         # This can happen if the file defines a class/module that doesn't match the filename convention
#         puts "[ERROR] FastMcp Initializer (mount_in_rails block): Could not load tool #{tool_class_name} from #{file}: #{e.message}"
#       rescue StandardError => e
#         puts "[ERROR] FastMcp Initializer (mount_in_rails block): Error loading tool #{tool_class_name} from #{file}: #{e.message}\n#{e.backtrace.join("\n")}"
#       end
#     end
#   else
#     puts "[WARN] FastMcp Initializer (mount_in_rails block): Tools directory #{tools_dir} not found."
#   end
#
#   # Dynamically load and register resources from app/resources
#   resources_path = Rails.root.join("app", "resources")
#   if Dir.exist?(resources_path)
#     Dir[resources_path.join("**", "*_resource.rb")].each do |file|
#       require_dependency file
#       resource_class_name = File.basename(file, ".rb").camelize
#       begin
#         resource_class = resource_class_name.safe_constantize
#         # Register all descendents, except the base class ApplicationResource
#         if resource_class && resource_class != ApplicationResource && resource_class < FastMcp::Resource
#           server.register_resource(resource_class) # Register the class
#           puts "[DEBUG] FastMcp Initializer (mount_in_rails block): Registered resource #{resource_class_name}" if debug_mode
#         else
#           puts "[WARN] FastMcp Initializer (mount_in_rails block): #{resource_class_name} from #{file} does not inherit from FastMcp::Resource or could not be loaded"
#         end
#       rescue StandardError => e
#         puts "[ERROR] FastMcp Initializer (mount_in_rails block): Error loading resource #{resource_class_name} from #{file}: #{e.message}"
#       end
#     end
#   else
#     puts "[WARN] FastMcp Initializer (mount_in_rails block): Resources directory #{resources_path} not found."
#   end
#
#   # You can access the globally set server via FastMcp.server if needed elsewhere
#   # puts "[DEBUG] FastMcp Initializer (mount_in_rails block): FastMcp.server tools: #{FastMcp.server.tools.keys.join(', ')}" if debug_mode
#   # puts "[DEBUG] FastMcp Initializer (mount_in_rails block): FastMcp.server resources: #{FastMcp.server.resources.keys.join(', ')}" if debug_mode
# end
#
# puts "[DEBUG] FastMcp Initializer: Finished setup using mount_in_rails." if debug_mode
