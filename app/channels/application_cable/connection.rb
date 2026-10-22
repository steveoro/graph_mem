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
      role = session_data&.dig("role")
      # Accept legacy key from sessions that haven't been rotated yet.
      legacy = session_data&.dig("operator_signed_in")

      reject_unauthorized_connection unless role == "operator" || legacy == true

      session_data&.dig("user") || "operator"
    end

    def decrypt_session_cookie
      session_key = Rails.application.config.session_options[:key]
      cookies.encrypted[session_key]
    rescue StandardError
      nil
    end
  end
end
