Rails.application.config.after_initialize do
  # Explicitly load application tool files
  # puts "[ActionMCP DEBUG via puts] (after_initialize) Initializer: Starting to explicitly load app tools..."

  # Define the paths to your base tool classes that others might depend on
  # Order matters if ApplicationTool depends on ApplicationMCPTool (which it does)
  base_tool_files_paths = [
    Rails.root.join("app/mcp/tools/application_mcp_tool.rb"),
    Rails.root.join("app/mcp/tools/application_tool.rb")
  ]
  # Convert to strings for simple include? check later if needed, and for require
  base_tool_files_strings = base_tool_files_paths.map(&:to_s)

  base_tool_files_paths.each do |file_path|
    if file_path.exist?
      # puts "[ActionMCP DEBUG via puts] (after_initialize)   Requiring MCP base tool file: #{file_path}"
      require file_path.to_s # require needs a string
    else
      # This might happen if a file is removed, good to log
      # puts "[ActionMCP DEBUG via puts] (after_initialize)   WARNING: Base tool file not found, skipping: #{file_path}"
    end
  end

  # Then load all other tools in the directory.
  # `require` is idempotent, so it won't reload if already loaded by the explicit requires above.
  # We sort to be systematic.
  Dir[Rails.root.join("app/mcp/tools/**/*.rb")].sort.each do |file|
    # Avoid re-logging for files already explicitly loaded, actual re-require is handled by Ruby's `require`
    unless base_tool_files_strings.include?(file)
      # puts "[ActionMCP DEBUG via puts] (after_initialize)   Requiring MCP tool file: #{file}"
      require file
    end
  end

  # puts "[ActionMCP DEBUG via puts] (after_initialize) Initializer: Finished explicitly loading app tools."
end
