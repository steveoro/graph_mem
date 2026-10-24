# frozen_string_literal: true

require "rails_helper"

# mcp plan PR-2 §2.21: the guard in spec/support/outbound_http_guard.rb.
RSpec.describe OutboundHttpGuard do
  it "refuses a non-loopback host before resolving it" do
    expect(Addrinfo).not_to receive(:getaddrinfo)
    expect(TCPSocket).not_to receive(:open)

    expect { Net::HTTP.get(URI("http://guard-probe.test:11434/")) }
      .to raise_error(described_class::BlockedError, /guard-probe\.test:11434/)

    # The after hook would fail this example on the recorded attempt; clear it here.
    expect(described_class.drain!).to eq([ "guard-probe.test:11434" ])
  end

  it "lets loopback through" do
    expect { Net::HTTP.get(URI("http://127.0.0.1:9/")) }.to raise_error(Errno::ECONNREFUSED)
    expect(described_class.drain!).to be_empty
  end

  it "refuses loopback on Ollama's default port" do
    expect { Net::HTTP.get(URI("http://localhost:11434/api/tags")) }
      .to raise_error(described_class::BlockedError, /localhost:11434/)
    expect(described_class.drain!).to eq([ "localhost:11434" ])
  end

  it "treats localhost, 127.0.0.0/8 and ::1 as loopback, and nothing else" do
    %w[localhost LOCALHOST 127.0.0.1 127.1.2.3 ::1 [::1]].each do |host|
      expect(described_class.allowed_host?(host)).to be(true), host
    end
    %w[10.0.0.1 192.168.1.10 summary.test example.com].push("", nil).each do |host|
      expect(described_class.allowed_host?(host)).to be(false), host.inspect
    end
  end
end
