# frozen_string_literal: true

require "ipaddr"
require "net/http"

# mcp plan PR-2 §2.21: no spec may open an outbound HTTP connection.
#
# The app's only outbound clients (EmbeddingService, SummaryGenerationClient) use
# Net::HTTP, so a small guard on Net::HTTP#connect is enough (no WebMock dependency).
# It refuses any host that isn't loopback before DNS is resolved, so a fake
# `*.test` URL can't hang on a resolver that answers every name. Loopback stays
# allowed for Capybara's server, the Selenium driver and `OLLAMA_URL=http://127.0.0.1:9`,
# except Ollama's default port, so a dev box's real Ollama is never reached.
#
# The services rescue their own errors, so a refused call could pass unnoticed;
# every attempt is also recorded, and the example fails in an `after` hook.
# Stub at the service boundary instead (`SummaryGenerationClient.generate`,
# `EmbeddingService.instance` / `vector_enabled?`, see `spec/support/embedding_helper.rb`).
module OutboundHttpGuard
  # Raised in place of an outbound connection to a non-loopback host.
  class BlockedError < StandardError; end

  LOOPBACK_NAMES = %w[localhost].freeze
  OLLAMA_DEFAULT_PORT = 11_434

  @attempts = []
  @mutex = Mutex.new

  class << self
    # @param host [String, nil] the Net::HTTP address
    # @param port [Integer, nil] the Net::HTTP port
    # @return [Boolean] true for localhost, 127.0.0.0/8 and ::1 on any port but 11434
    def allowed?(host, port)
      port.to_i != OLLAMA_DEFAULT_PORT && allowed_host?(host)
    end

    # @param host [String, nil] the Net::HTTP address
    # @return [Boolean] true for localhost, 127.0.0.0/8 and ::1
    def allowed_host?(host)
      name = host.to_s.delete_prefix("[").delete_suffix("]").downcase
      return true if LOOPBACK_NAMES.include?(name)

      IPAddr.new(name).loopback?
    rescue IPAddr::InvalidAddressError
      false
    end

    # @param target [String] "host:port" of the refused connection
    # @return [void]
    def record(target)
      @mutex.synchronize { @attempts << target }
    end

    # Returns and clears the refused connections recorded so far.
    # @return [Array<String>]
    def drain!
      @mutex.synchronize { @attempts.slice!(0..) }
    end
  end

  # Prepended to Net::HTTP.
  module NetHttpConnect
    private

    def connect
      return super if OutboundHttpGuard.allowed?(address, port)

      target = "#{address}:#{port}"
      OutboundHttpGuard.record(target)
      raise OutboundHttpGuard::BlockedError,
        "Outbound HTTP to #{target} blocked in specs; stub the service boundary instead"
    end
  end
end

Net::HTTP.prepend(OutboundHttpGuard::NetHttpConnect)

RSpec.configure do |config|
  config.before { OutboundHttpGuard.drain! }

  config.after do
    blocked = OutboundHttpGuard.drain!
    next if blocked.empty?

    raise OutboundHttpGuard::BlockedError,
      "This example tried outbound HTTP to #{blocked.uniq.join(', ')}; stub the service boundary instead"
  end
end
