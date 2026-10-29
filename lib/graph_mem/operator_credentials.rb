# frozen_string_literal: true

module GraphMem
  # Whether the operator's sign-in is configured (UI-7 S6), for Operator::SessionsController and
  # System › Access. Never exposes the username or password, nor their length.
  module OperatorCredentials
    # The documented fallback password; production refuses to sign in with it.
    FALLBACK_PASSWORD = "changeme"

    module_function

    # @return [Boolean] a password is set in OPERATOR_PASSWORD or the credentials (operator.password)
    def configured?
      (ENV["OPERATOR_PASSWORD"].presence || Rails.application.credentials.dig(:operator, :password)).present?
    end

    # The default username ("operator") is public and documented; only the default password is a
    # risk, so only that locks production out.
    #
    # @return [Boolean]
    def production_fallback?
      Rails.env.production? && ApplicationController.operator_password == FALLBACK_PASSWORD
    end

    # @return [Symbol] :configured, :fallback_refused (production, default password) or :fallback
    def status
      return :fallback_refused if production_fallback?

      configured? && ApplicationController.operator_password != FALLBACK_PASSWORD ? :configured : :fallback
    end
  end
end
