# frozen_string_literal: true

# Home's embedding probe is a real HTTP GET of the embedding service's base URL, which defaults
# to localhost:11434 when OLLAMA_URL isn't set (as on CI). Stub it at the service boundary for
# every example; a spec that tests the probe itself calls the original with an unroutable URL.
RSpec.configure do |config|
  config.before { allow(HomeSnapshot::Health).to receive(:embedding_reachable?).and_return(false) }
end
