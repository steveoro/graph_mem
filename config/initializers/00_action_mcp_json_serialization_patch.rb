# frozen_string_literal: true

# This initializer patches ActionMCP models to ensure correct JSON serialization
# for attributes that are stored in TEXT columns in MariaDB but represent JSON data.
#
# == Rationale behind this patch:
# 1. MariaDB and its future vector database integrated support, is our database of choice;
# 2. the actionmcp gem uses JSONB columns for storing JSON data as it implies Postgresql usage;
# 3. MariaDB json column add a stricter validation constraint that simply fails when applied
#    to Ruby hash objects;
# 4. the workaround uses plain text columns on the database, plus a JSON coder for all serialized
#    attributes (which is roughly equivalent to have an Hash value .to_json and re-parse it from text);
#
# == Recap - main differences with the original ActionMCP gem:
# 1. JSONB columns stored as text;
# 2. added serialization of text as JSON;
#

Rails.application.config.to_prepare do
  # Ensure the original classes are loaded before trying to patch them.
  # Referencing them should trigger autoloading if they haven't been loaded yet.
  begin
    _session_ref = ActionMCP::Session
    _message_ref = ActionMCP::Session::Message
    _resource_ref = ActionMCP::Session::Resource
  rescue NameError => e
    puts "[MCP PATCH] Error referencing ActionMCP models for patching: #{e.message}. Patches might not be applied."
    # If models aren't defined, we can't patch them. This might indicate a load order issue
    # or that the actionmcp gem is not loaded as expected.
    next # Skip patching if essential classes are missing
  end

  ActionMCP::Session.class_eval do
    # Check if serialize has already been called to avoid issues if the initializer runs multiple times (e.g. in dev with reloads)
    # ActiveRecord::Base.attribute_types gives us info about how attributes are handled.
    # For serialized attributes, the type will be an instance of ActiveRecord::Type::Serialized.

    # Columns for ActionMCP::Session
    attrs_to_serialize_session = {
      server_capabilities: JSON,
      server_info: JSON,
      client_capabilities: JSON,
      client_info: JSON,
      tool_registry: JSON,
      prompt_registry: JSON,
      resource_registry: JSON
    }

    attrs_to_serialize_session.each do |attr_name, coder|
      # Check if the attribute is already serialized with the correct coder
      current_type = attribute_types[attr_name.to_s]
      if current_type.is_a?(ActiveRecord::Type::Serialized) && current_type.coder == coder
        # puts "[MCP PATCH] ActionMCP::Session##{attr_name} already serialized with #{coder}."
      else
        serialize attr_name, coder: coder
        # puts "[MCP PATCH] ActionMCP::Session##{attr_name} patched to serialize with #{coder}."
      end
    end
  end

  ActionMCP::Session::Message.class_eval do
    attrs_to_serialize_message = { message_json: JSON }

    attrs_to_serialize_message.each do |attr_name, coder|
      current_type = attribute_types[attr_name.to_s]
      if current_type.is_a?(ActiveRecord::Type::Serialized) && current_type.coder == coder
        # puts "[MCP PATCH] ActionMCP::Session::Message##{attr_name} already serialized with #{coder}."
      else
        serialize attr_name, coder: coder
        # puts "[MCP PATCH] ActionMCP::Session::Message##{attr_name} patched to serialize with #{coder}."
      end
    end
  end

  ActionMCP::Session::Resource.class_eval do
    attrs_to_serialize_resource = { metadata: JSON }

    attrs_to_serialize_resource.each do |attr_name, coder|
      current_type = attribute_types[attr_name.to_s]
      if current_type.is_a?(ActiveRecord::Type::Serialized) && current_type.coder == coder
        # puts "[MCP PATCH] ActionMCP::Session::Resource##{attr_name} already serialized with #{coder}."
      else
        serialize attr_name, coder: coder
        # puts "[MCP PATCH] ActionMCP::Session::Resource##{attr_name} patched to serialize with #{coder}."
      end
    end
  end

  # puts "[MCP PATCH] JSON serialization patches applied to ActionMCP models."
rescue NameError => e
  # This rescue block is for NameErrors that might occur if ActionMCP or its submodules aren't loaded
  puts "[MCP PATCH] Failed to apply JSON serialization patches. ActionMCP module or one of its classes/modules not found: #{e.message}"
rescue StandardError => e
  puts "[MCP PATCH] An unexpected error occurred while applying JSON serialization patches: #{e.class.name}: #{e.message}\n#{e.backtrace.join("\n")}"
end
