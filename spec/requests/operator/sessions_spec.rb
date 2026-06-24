# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Operator sessions", type: :request do
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

    it "rejects invalid credentials" do
      post operator_session_path, params: { username: "wrong", password: "nope" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Invalid username or password")
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
end
