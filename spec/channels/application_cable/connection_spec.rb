# frozen_string_literal: true

require "rails_helper"

# ActionCable::Connection::TestCase uses TestCookieJar.encrypted (a plain
# TestCookies hash) — no real encryption happens here. Setting
#   cookies.encrypted[key] = { value: data }
# stores `data` directly, and reading cookies.encrypted[key] returns it.
# This mirrors what the real EncryptedKeyRotatingCookieJar does at the
# interface level without the full crypto stack.
RSpec.describe ApplicationCable::Connection, type: :channel do
  let(:session_key) { Rails.application.config.session_options[:key] }

  describe "with an operator session (new role key)" do
    it "connects and identifies as the operator username" do
      cookies.encrypted[session_key] = { value: { "role" => "operator", "user" => "test_op" } }
      connect
      expect(connection.operator).to eq("test_op")
    end
  end

  describe "with a legacy operator session (operator_signed_in key)" do
    it "connects and identifies as 'operator'" do
      cookies.encrypted[session_key] = { value: { "operator_signed_in" => true } }
      connect
      expect(connection.operator).to eq("operator")
    end
  end

  describe "without a session" do
    it "rejects the connection" do
      expect { connect }.to have_rejected_connection
    end
  end

  describe "with a non-operator session" do
    it "rejects the connection" do
      cookies.encrypted[session_key] = { value: { "role" => "guest" } }
      expect { connect }.to have_rejected_connection
    end
  end

  describe "with an expired operator session" do
    it "rejects a session idle past the idle timeout" do
      stale = Time.current.to_i - ApplicationController::SESSION_IDLE_TIMEOUT.to_i - 60
      cookies.encrypted[session_key] = {
        value: { "role" => "operator", "last_seen_at" => stale, "signed_in_at" => Time.current.to_i }
      }
      expect { connect }.to have_rejected_connection
    end

    it "rejects a session past the absolute timeout" do
      old = Time.current.to_i - ApplicationController::SESSION_ABSOLUTE_TIMEOUT.to_i - 60
      cookies.encrypted[session_key] = {
        value: { "role" => "operator", "last_seen_at" => Time.current.to_i, "signed_in_at" => old }
      }
      expect { connect }.to have_rejected_connection
    end
  end
end
