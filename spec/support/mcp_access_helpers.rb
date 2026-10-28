# frozen_string_literal: true

# OfficialMcp.access_policy is memoized and now reads the Settings › MCP access rows, which the
# transactional fixtures roll back after each example: drop the memo so no example sees the
# previous one's policy. Transports are left alone (specs that touch them reset them).
RSpec.configure do |config|
  config.before { GraphMem::OfficialMcp.refresh_access!(transports: false) }
end
