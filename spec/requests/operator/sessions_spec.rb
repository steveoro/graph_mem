# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Operator sessions", type: :request do
  include ActiveSupport::Testing::TimeHelpers
  describe "GET /operator/login" do
    it "renders the login form" do
      get operator_login_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Operator Sign In")
      expect(response.body).to include('data-testid="operator-login-form"')
    end

    it "redirects signed-in operators to the dashboard" do
      sign_in_operator
      get operator_login_path

      expect(response).to redirect_to(root_path)
    end
  end

  describe "POST /operator/login" do
    it "signs in with valid credentials" do
      post operator_session_path,
           params: { username: OperatorAuthHelpers::TEST_OPERATOR_USERNAME,
                     password: OperatorAuthHelpers::TEST_OPERATOR_PASSWORD }

      expect(response).to redirect_to(root_path)
      follow_redirect!
      expect(response.body).to include("Operator Dashboard")
    end

    it "rotates the session id on sign-in (session fixation protection)" do
      get operator_login_path
      old_session_id = session.id.to_s

      post operator_session_path,
           params: { username: OperatorAuthHelpers::TEST_OPERATOR_USERNAME,
                     password: OperatorAuthHelpers::TEST_OPERATOR_PASSWORD }

      expect(session.id.to_s).not_to eq(old_session_id)
    end

    it "sets the role, user, and timestamp session keys" do
      post operator_session_path,
           params: { username: OperatorAuthHelpers::TEST_OPERATOR_USERNAME,
                     password: OperatorAuthHelpers::TEST_OPERATOR_PASSWORD }

      expect(session[:role]).to eq("operator")
      expect(session[:user]).to eq(OperatorAuthHelpers::TEST_OPERATOR_USERNAME)
      expect(session[:signed_in_at]).to be_a(Integer).and be_within(5).of(Time.current.to_i)
      expect(session[:last_seen_at]).to be_a(Integer).and be_within(5).of(Time.current.to_i)
    end

    it "rejects invalid credentials" do
      post operator_session_path, params: { username: "wrong", password: "nope" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Invalid username or password")
    end

    it "returns 429 after 10 failed attempts" do
      # config.action_controller.cache_store = :memory_store in test.rb enables
      # the rate-limit counter. Isolate this example so the counter from 11
      # failed POSTs does not bleed into subsequent sign-in tests.
      store = Operator::SessionsController.cache_store
      store.clear
      begin
        11.times { post operator_session_path, params: { username: "wrong", password: "bad" } }
        expect(response).to have_http_status(:too_many_requests)
      ensure
        store.clear
      end
    end
  end

  describe "DELETE /operator/logout" do
    it "signs out and redirects to login" do
      sign_in_operator
      delete operator_logout_path

      expect(response).to redirect_to(operator_login_path)
      get root_path
      expect(response).to redirect_to(operator_login_path)
    end
  end

  describe "protected dashboard" do
    it "redirects unauthenticated users to login" do
      get root_path

      expect(response).to redirect_to(operator_login_path)
    end

    it "allows authenticated operators to access the dashboard" do
      sign_in_operator
      get root_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Operator Dashboard")
    end
  end

  describe "session expiry" do
    it "expires an idle session after the idle timeout" do
      sign_in_operator
      # travel_to beyond the idle window — the controller compares
      # Time.current.to_i against session[:last_seen_at] set at login.
      travel_to (ApplicationController::SESSION_IDLE_TIMEOUT + 1.minute).from_now do
        get root_path
        expect(response).to redirect_to(operator_login_path)
      end
    end

    it "expires an absolute session after the absolute timeout" do
      sign_in_operator
      travel_to (ApplicationController::SESSION_ABSOLUTE_TIMEOUT + 1.minute).from_now do
        get root_path
        expect(response).to redirect_to(operator_login_path)
      end
    end
  end

  context "when OPERATOR_USERNAME and OPERATOR_PASSWORD are blank" do
    # Set in `before` (not `around`): the global request-spec hook in
    # operator_auth_helpers.rb overwrites ENV, and context hooks run after it.
    before do
      @original_env = ENV.values_at("OPERATOR_USERNAME", "OPERATOR_PASSWORD")
      ENV["OPERATOR_USERNAME"] = ""
      ENV["OPERATOR_PASSWORD"] = ""
      allow(Rails.application.credentials).to receive(:dig).and_return(nil)
    end

    after do
      ENV["OPERATOR_USERNAME"], ENV["OPERATOR_PASSWORD"] = @original_env
    end

    it "rejects login with empty params and sets no session" do
      post operator_session_path, params: { username: "", password: "" }
      expect(response).to have_http_status(:unprocessable_content)
      get operator_login_path
      expect(response).to have_http_status(:ok)
    end

    it "rejects login with missing params" do
      post operator_session_path
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "falls back to the operator/changeme defaults" do
      post operator_session_path, params: { username: "operator", password: "changeme" }
      expect(response).to redirect_to(root_path)
    end
  end

  it "redirects to the originally requested page after login" do
    get graph_path
    expect(response).to redirect_to(operator_login_path)

    post operator_session_path, params: {
      username: OperatorAuthHelpers::TEST_OPERATOR_USERNAME,
      password: OperatorAuthHelpers::TEST_OPERATOR_PASSWORD
    }
    expect(response).to redirect_to(graph_path)
  end

  describe "production with default (fallback) credentials" do
    before do
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
      # Ensure operator falls back to the defaults
      ENV.delete("OPERATOR_USERNAME")
      ENV.delete("OPERATOR_PASSWORD")
      allow(Rails.application.credentials).to receive(:dig).and_return(nil)
    end

    it "shows the configuration error page instead of the login form" do
      get operator_login_path
      expect(response).to have_http_status(:service_unavailable)
    end
  end

  describe "production with a custom password" do
    before do
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
      ENV.delete("OPERATOR_USERNAME") # username resolves to the public default "operator"
      ENV["OPERATOR_PASSWORD"] = "a-strong-secret"
      allow(Rails.application.credentials).to receive(:dig).and_return(nil)
    end

    it "renders the login form" do
      get operator_login_path
      expect(response).to have_http_status(:ok)
    end

    it "accepts the configured credentials" do
      post operator_session_path, params: { username: "operator", password: "a-strong-secret" }
      expect(response).to redirect_to(root_path)
    end
  end
end
