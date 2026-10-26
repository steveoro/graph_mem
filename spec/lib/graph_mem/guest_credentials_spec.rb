# frozen_string_literal: true

require "rails_helper"

RSpec.describe GraphMem::GuestCredentials do
  let(:password) { "synthetic-guest-secret" }

  around do |example|
    operator = %w[OPERATOR_USERNAME OPERATOR_PASSWORD].to_h { |key| [ key, ENV[key] ] }
    ENV["OPERATOR_USERNAME"] = "test_operator"
    ENV["OPERATOR_PASSWORD"] = "test_secret"
    example.run
  ensure
    operator.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    AppSettings.enable_guest_access = true
  end

  def resolve(env: {}, credentials: {})
    described_class.resolve(env: env, credentials: credentials)
  end

  describe ".resolve" do
    it "prefers ENV over credentials for each field" do
      creds = resolve(
        env: { "GRAPH_MEM_GUEST_USERNAME" => "env-guest", "GRAPH_MEM_GUEST_PASSWORD" => "env-pass" },
        credentials: { guest: { username: "cred-guest", password: "cred-pass" } }
      )

      expect(creds.username).to eq("env-guest")
      expect(creds.matches?("env-guest", "env-pass")).to be true
      expect(creds.matches?("cred-guest", "cred-pass")).to be false
    end

    it "falls through blank ENV values to credentials" do
      creds = resolve(
        env: { "GRAPH_MEM_GUEST_USERNAME" => "", "GRAPH_MEM_GUEST_PASSWORD" => "" },
        credentials: { guest: { username: "cred-guest", password: "cred-pass" } }
      )

      expect(creds.username).to eq("cred-guest")
      expect(creds.matches?("cred-guest", "cred-pass")).to be true
    end

    it "is not configured when nothing is set, with the default username" do
      creds = resolve

      expect(creds.configured?).to be false
      expect(creds.username).to eq("guest")
      expect(creds.status).to eq(:not_configured)
      expect(creds.available?).to be false
    end

    it "has no default password" do
      expect(resolve.instance_variable_get(:@password)).to be_nil
      expect(resolve.matches?("guest", "")).to be false
      expect(resolve.matches?("guest", "guest")).to be false
    end
  end

  describe "#status" do
    it "is available with a password, no clash and the toggle on" do
      expect(resolve(env: { "GRAPH_MEM_GUEST_PASSWORD" => password }).status).to eq(:available)
    end

    it "is a conflict when the username equals the operator's" do
      creds = resolve(env: { "GRAPH_MEM_GUEST_USERNAME" => "test_operator", "GRAPH_MEM_GUEST_PASSWORD" => password })

      expect(creds.status).to eq(:conflict)
      expect(creds.available?).to be false
    end

    it "is a conflict when the password equals the operator's" do
      expect(resolve(env: { "GRAPH_MEM_GUEST_PASSWORD" => "test_secret" }).status).to eq(:conflict)
    end

    it "is disabled when the toggle is off" do
      AppSettings.enable_guest_access = false

      creds = resolve(env: { "GRAPH_MEM_GUEST_PASSWORD" => password })

      expect(creds.status).to eq(:disabled)
      expect(creds.matches?("guest", password)).to be false
    end
  end

  describe "#fingerprint" do
    it "changes with the password and never contains it" do
      first = resolve(env: { "GRAPH_MEM_GUEST_PASSWORD" => password }).fingerprint
      second = resolve(env: { "GRAPH_MEM_GUEST_PASSWORD" => "#{password}-rotated" }).fingerprint

      expect(first).to match(/\A\h{32}\z/)
      expect(first).not_to eq(second)
      expect(first).not_to include(password)
    end
  end

  it "keeps the password out of inspect and to_s" do
    creds = resolve(env: { "GRAPH_MEM_GUEST_PASSWORD" => password })

    expect(creds.inspect).not_to include(password)
    expect(creds.to_s).not_to include(password)
  end

  describe ".credentials_store" do
    it "treats an unreadable credentials file as not configured" do
      store = instance_double(ActiveSupport::EncryptedConfiguration)
      allow(store).to receive(:config).and_raise(ActiveSupport::MessageEncryptor::InvalidMessage)
      allow(Rails.application).to receive(:credentials).and_return(store)

      expect(described_class.credentials_store).to eq({})
      expect(resolve(credentials: described_class.credentials_store).configured?).to be false
    end
  end

  describe ".current" do
    it "memoises until reset!" do
      described_class.reset!
      allow(described_class).to receive(:resolve).and_call_original

      2.times { described_class.current }
      described_class.reset!
      described_class.current

      expect(described_class).to have_received(:resolve).twice
    ensure
      described_class.reset!
    end
  end
end
