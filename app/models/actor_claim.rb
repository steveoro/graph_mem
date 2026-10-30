# frozen_string_literal: true

# What an MCP client says about itself (audit actor, 1.65.0), stored next to the server-side
# `actor` as `actor_claim` and shown as "claimed: …". Self-reported and display-only: nothing
# authorizes, credits, filters or decides a policy from it. Every part is sanitized (no control or
# format characters, spaces squeezed) and the whole value is truncated to MAX_LENGTH.
#
#   ActorClaim.transport(client_id: "synth-client-a", client_info: { name: "claude-code", version: "2.1.0" })
#   # => "client=synth-client-a · claude-code/2.1.0"
#   ActorClaim.source_parts("claude-code/opus: fact supersede review")
#   # => ["claude-code/opus", "fact supersede review"]
#   ActorClaim.join("client=synth-client-a", "claude-code/opus") # => "client=synth-client-a · claude-code/opus"
module ActorClaim
  SEPARATOR = " · "
  MAX_LENGTH = 255
  # The documented `source` form "<client>/<model>: <task>", on one line. "project_scan:…",
  # "docs:…" or "operator" have no slash before the colon, so they give no claim and no reason.
  SOURCE_PATTERN = %r{\A(?<who>[A-Za-z0-9._-]+/[A-Za-z0-9._:@-]+):\s+(?<why>\S.*)\z}

  module_function

  # The per-call claim: the X-MCP-Client id (unless it's the default) and the MCP initialize
  # clientInfo name/version.
  #
  # @param client_id [String, nil] the normalized X-MCP-Client
  # @param client_info [Hash, nil] `{ name:, version: }` (symbol or string keys); anything else is ignored
  # @return [String, nil]
  def transport(client_id:, client_info:)
    client = "client=#{client_id}" if client_id.present? && client_id != GraphMemContext::DEFAULT_CLIENT_ID
    join(client, software(client_info))
  end

  # @param source [String, nil] an observation's source
  # @return [Array(String, String), nil] the `who` and `why` of "<client>/<model>: <task>"
  def source_parts(source)
    text = source.to_s
    return if text.include?("\n") || text.include?("\r")

    match = SOURCE_PATTERN.match(text.strip)
    return unless match

    why = sanitize(match[:why])
    [ match[:who], why ] if why.present?
  end

  # @param parts [Array<String, nil>]
  # @return [String, nil] the sanitized parts joined with SEPARATOR, truncated; nil when all are blank
  def join(*parts)
    joined = parts.filter_map { |part| sanitize(part).presence }.join(SEPARATOR)
    joined.presence&.truncate(MAX_LENGTH, omission: "…")
  end

  # @param text [String, nil]
  # Control characters (Cc) and format characters (Cf: bidi overrides and isolates, zero-width
  # characters), which could make a claim look like something else, become spaces.
  #
  # @return [String] without control or format characters, spaces squeezed, at most MAX_LENGTH characters
  def sanitize(text)
    text.to_s.gsub(/[[:cntrl:]\p{Cf}]+/, " ").squish.truncate(MAX_LENGTH, omission: "…")
  end

  def software(client_info)
    return unless client_info.is_a?(Hash)

    name = client_info[:name] || client_info["name"]
    version = client_info[:version] || client_info["version"]
    return if name.blank?

    version.present? ? "#{name}/#{version}" : name.to_s
  end
  private_class_method :software
end
