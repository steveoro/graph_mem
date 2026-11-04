# frozen_string_literal: true

namespace :llm do
  # Agent-CLI PR4: asks the host bridge for its health once and prints one line per profile (no
  # path, no token). Reads LLM_BRIDGE_URL and LLM_BRIDGE_TOKEN_FILE like the app.
  desc "Report whether the LLM host bridge is configured and reachable, and each profile's gate"
  task bridge_probe: :environment do
    probe = Llm::BridgeProbe.call
    unless probe[:reachable]
      puts "bridge: #{probe[:configured] ? 'not reachable' : 'not configured'} (#{probe[:reason]})"
      next
    end

    puts "bridge: reachable (version #{probe[:bridge_version] || '?'})"
    probe[:profiles].each do |name, info|
      gate = info[:gate_result] ? "#{info[:gate_result]} (passed on #{info[:passed_on] || '?'})" : "none"
      puts "  #{name}: cli #{info[:cli_ok] ? 'found' : 'missing'}, gate #{gate}, #{info[:gate_ok] ? 'usable' : 'not usable'}" \
           "#{', TRIPPED' if info[:tripped]}"
    end
  end
end
