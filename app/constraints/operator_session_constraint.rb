# frozen_string_literal: true

# Route constraint that passes only when the request carries a valid operator session.
# Used to gate /api-docs (Rswag) behind authentication.
class OperatorSessionConstraint
  def matches?(request)
    session_key = Rails.application.config.session_options[:key]
    session_data = request.cookie_jar.encrypted[session_key] || {}
    session_data["role"] == "operator"
  rescue StandardError
    false
  end
end
