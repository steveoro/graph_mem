# frozen_string_literal: true

module Operator
  # What Settings › MCP access shows for each allowlist (UI-2a A3): the ENV value as a read-only
  # prefix, the editable additive part, the effective merged list and the notes beside it.
  module McpAccessHelper
    LISTS = GraphMem::McpAccessLists

    # @return [Array<Hash>] one row per list (:ips, :hosts, :origins), with :kind, :key, :env_var,
    #   :env_value (nil when unset), :env_warnings, :input, :disabled, :effective (Array<String>),
    #   :notes (Array<String>, per stored entry) and :errors
    def mcp_access_rows
      policy = GraphMem::OfficialMcp.access_policy
      LISTS::SETTING_KEYS.map do |kind, key|
        extras = LISTS.extra_entries(kind)
        {
          kind: kind, key: key, env_var: LISTS::KINDS[kind],
          env_value: ENV[LISTS::KINDS[kind]].to_s.strip.presence,
          env_warnings: LISTS.env_warnings(kind),
          input: params.dig(:settings, key) || extras.join(", "),
          disabled: kind == :ips && policy.network_unrestricted?,
          effective: mcp_access_effective(kind, policy),
          notes: kind == :ips ? mcp_access_ip_notes(extras, policy) : [],
          errors: Array(@mcp_access_errors&.dig(kind))
        }
      end
    end

    private

    def mcp_access_effective(kind, policy)
      case kind
      when :ips
        policy.allowed_ips.map { |range| range.prefix == (range.ipv4? ? 32 : 128) ? range.to_s : "#{range}/#{range.prefix}" }
      when :hosts then GraphMem::McpAccessLists::Validator::LOOPBACK_HOSTS + LISTS.entries(:hosts)
      else LISTS.entries(:origins)
      end
    end

    # A stored public range is marked; without a token now, it is also inactive (not in the
    # effective list: McpAccessPolicy re-checks it on every build).
    def mcp_access_ip_notes(extras, policy)
      extras.filter_map do |entry|
        next unless GraphMem::McpAccessLists::Validator.public_ip?(entry)

        note = t("system.settings.mcp_access.public_entry", entry: entry)
        policy.token_required? ? note : "#{note} #{t('system.settings.mcp_access.inactive_no_token')}"
      end
    end
  end
end
