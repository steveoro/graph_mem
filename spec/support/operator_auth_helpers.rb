# frozen_string_literal: true

module OperatorAuthHelpers
  TEST_OPERATOR_USERNAME = "test_operator"
  TEST_OPERATOR_PASSWORD = "test_secret"
  TEST_GUEST_PASSWORD = "synthetic-guest-secret"
  GUEST_ENV_KEYS = [ GraphMem::GuestCredentials::USERNAME_ENV, GraphMem::GuestCredentials::PASSWORD_ENV ].freeze

  def operator_auth_headers
    {}
  end

  def sign_in_operator(username: TEST_OPERATOR_USERNAME, password: TEST_OPERATOR_PASSWORD)
    post operator_session_path, params: { username: username, password: password }
  end

  # Configures the guest account through ENV (never the real credentials file).
  # @param username [String, nil] nil keeps the default "guest"
  # @param password [String]
  def enable_guest!(username: nil, password: TEST_GUEST_PASSWORD)
    ENV[GraphMem::GuestCredentials::PASSWORD_ENV] = password
    username ? ENV[GraphMem::GuestCredentials::USERNAME_ENV] = username : ENV.delete(GraphMem::GuestCredentials::USERNAME_ENV)
    GraphMem::GuestCredentials.reset!
  end

  def sign_in_guest(username: GraphMem::GuestCredentials.current.username, password: TEST_GUEST_PASSWORD)
    post operator_session_path, params: { username: username, password: password }
  end

  # Specs must never depend on what config/credentials.yml.enc holds on this machine.
  def isolate_guest_credentials!
    GUEST_ENV_KEYS.each { |key| ENV.delete(key) }
    allow(GraphMem::GuestCredentials).to receive(:credentials_store).and_return({})
    GraphMem::GuestCredentials.reset!
  end
end

RSpec.configure do |config|
  config.include OperatorAuthHelpers, type: :request
  config.include OperatorAuthHelpers, type: :system

  config.before(:each, type: :request) do
    ENV["OPERATOR_USERNAME"] = OperatorAuthHelpers::TEST_OPERATOR_USERNAME
    ENV["OPERATOR_PASSWORD"] = OperatorAuthHelpers::TEST_OPERATOR_PASSWORD
    isolate_guest_credentials!
    # Clear the rate-limit MemoryStore before every example so counters from one
    # test never bleed into the next. (rate_limit counts ALL POST /operator/session
    # requests — including successful sign_in_operator calls — so 10+ sign-ins
    # across the suite would exhaust the 10/3min window and return 429.)
    Operator::SessionsController.cache_store.clear
    # Auto sign-in for API v1 specs, except the dedicated authentication spec which
    # explicitly tests 401 / bearer-token scenarios without a pre-existing session.
    file = RSpec.current_example.metadata[:file_path].to_s
    if file.include?("requests/api/v1/") && !file.include?("authentication_spec") && !file.include?("guest_access_spec")
      sign_in_operator
    end
  end

  config.before(:each, type: :system) { isolate_guest_credentials! }

  %i[request system].each do |type|
    config.after(:each, type: type) do
      OperatorAuthHelpers::GUEST_ENV_KEYS.each { |key| ENV.delete(key) }
      GraphMem::GuestCredentials.reset!
    end
  end
end
