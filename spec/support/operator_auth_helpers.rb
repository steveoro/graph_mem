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

  config.before(:each, type: :request) do
    ENV["OPERATOR_USERNAME"] = OperatorAuthHelpers::TEST_OPERATOR_USERNAME
    ENV["OPERATOR_PASSWORD"] = OperatorAuthHelpers::TEST_OPERATOR_PASSWORD
    # Clear the rate-limit MemoryStore before every example so counters from one
    # test never bleed into the next. (rate_limit counts ALL POST /operator/session
    # requests — including successful sign_in_operator calls — so 10+ sign-ins
    # across the suite would exhaust the 10/3min window and return 429.)
    Operator::SessionsController.cache_store.clear
    # Auto sign-in for API v1 specs, except the dedicated authentication spec which
    # explicitly tests 401 / bearer-token scenarios without a pre-existing session.
    file = RSpec.current_example.metadata[:file_path].to_s
    if file.include?("requests/api/v1/") && !file.include?("authentication_spec")
      sign_in_operator
    end
  end
end
