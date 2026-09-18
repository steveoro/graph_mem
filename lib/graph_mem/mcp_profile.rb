# frozen_string_literal: true

module GraphMem
  # Selects the MCP tool catalog advertised for a connection endpoint.
  class McpProfile
    NAMES = %i[default readonly maintenance].freeze
    DEFAULT = :default
    ENV_KEY = "GRAPH_MEM_MCP_PROFILE"
    PATH_PREFIX = "/mcp"
    STREAMABLE_SUFFIXES = {
      "" => :default,
      "/" => :default,
      "/readonly" => :readonly,
      "/readonly/" => :readonly,
      "/maintenance" => :maintenance,
      "/maintenance/" => :maintenance
    }.freeze
    LEGACY_SUFFIXES = %w[/sse /messages].freeze

    class InvalidProfile < ArgumentError; end

    class << self
      def from_request(request)
        from_path(request.path)
      end

      def from_path(path)
        suffix = path.to_s.delete_prefix(PATH_PREFIX)
        return DEFAULT if LEGACY_SUFFIXES.include?(suffix)

        STREAMABLE_SUFFIXES.fetch(suffix) do
          raise InvalidProfile, "Unknown MCP profile path: #{path.inspect}"
        end
      end

      def from_env(env = ENV)
        normalize(env.fetch(ENV_KEY, DEFAULT.to_s))
      end

      def select_tools(tools, profile)
        normalized_profile = normalize(profile)
        tools.select { |tool_class| normalized_profile.in?(tool_class.mcp_profiles) }
      end

      def normalize(profile)
        normalized = profile.to_s.strip.downcase.to_sym
        return normalized if normalized.in?(NAMES)

        raise InvalidProfile,
              "Unknown MCP profile #{profile.inspect}; expected one of: #{NAMES.join(', ')}"
      end
    end
  end
end
