# frozen_string_literal: true

module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :operator

    def connect
      self.operator = find_verified_operator
    end

    private

    def find_verified_operator
      session_data = decrypt_session_cookie
      reject_unauthorized_connection unless operator_session?(session_data)

      session_data&.dig("user") || "operator"
    end

    def operator_session?(session_data)
      role = session_data&.dig("role")
      legacy = session_data&.dig("operator_signed_in")
      return false unless role == "operator" || legacy == true

      now = Time.current.to_i
      last_seen = session_data&.dig("last_seen_at")
      signed_in = session_data&.dig("signed_in_at")

      return false if last_seen && now - last_seen > ApplicationController::SESSION_IDLE_TIMEOUT.to_i
      return false if signed_in && now - signed_in > ApplicationController::SESSION_ABSOLUTE_TIMEOUT.to_i

      true
    end

    def decrypt_session_cookie
      session_key = Rails.application.config.session_options[:key]
      cookies.encrypted[session_key]
    rescue StandardError
      nil
    end
  end
end
