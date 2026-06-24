# frozen_string_literal: true

module OperatorAuthHelpers
  TEST_OPERATOR_USERNAME = "test_operator"
  TEST_OPERATOR_PASSWORD = "test_secret"

  def operator_auth_headers
    {}
  end

  def sign_in_operator(username: TEST_OPERATOR_USERNAME, password: TEST_OPERATOR_PASSWORD)
    post operator_session_path, params: { username: username, password: password }
  end
end

RSpec.configure do |config|
  config.include OperatorAuthHelpers, type: :request

  config.before(type: :request) do
    ENV["OPERATOR_USERNAME"] = OperatorAuthHelpers::TEST_OPERATOR_USERNAME
    ENV["OPERATOR_PASSWORD"] = OperatorAuthHelpers::TEST_OPERATOR_PASSWORD
  end
end
