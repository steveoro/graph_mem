# frozen_string_literal: true

class ApplicationPrompt < FastMcp::Prompt
  MCP_PROFILE_NAMES = %i[default readonly maintenance].freeze

  class << self
    # Declares which MCP connection profiles advertise and serve this prompt.
    # Prompts without a declaration are available on every profile.
    #
    # @param profiles [Array<Symbol>] subset of MCP_PROFILE_NAMES
    def mcp_metadata(profiles:)
      normalized_profiles = Array(profiles).map(&:to_sym).uniq
      unknown_profiles = normalized_profiles - MCP_PROFILE_NAMES
      raise ArgumentError, "Unknown MCP profiles: #{unknown_profiles.join(', ')}" if unknown_profiles.any?
      raise ArgumentError, "At least one MCP profile is required" if normalized_profiles.empty?

      @mcp_profiles = normalized_profiles.freeze
    end

    def mcp_profiles
      @mcp_profiles || MCP_PROFILE_NAMES
    end
  end
end
