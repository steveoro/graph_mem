# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Guest sign-in", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:guest_password) { OperatorAuthHelpers::TEST_GUEST_PASSWORD }

  after { AppSettings.enable_guest_access = true }

  def sidebar
    Nokogiri::HTML(response.body).at_css("nav.ui-sidebar")
  end

  context "with nothing configured" do
    [ "guest", "", "changeme", OperatorAuthHelpers::TEST_GUEST_PASSWORD ].each do |password|
      it "refuses guest with password #{password.inspect} like any wrong login" do
        post operator_session_path, params: { username: "guest", password: password }

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t("operator.sessions.invalid_credentials"))
        # The form echoes the submitted username; the visible text must not mention a guest.
        expect(Nokogiri::HTML(response.body).at_css("main").text).not_to match(/guest/i)
        expect(session[:role]).to be_nil
      end
    end
  end

  context "with a guest password in ENV" do
    before { enable_guest! }

    it "signs in with the toggle at its default and lands on /search with the guest nav" do
      sign_in_guest
      expect(response).to redirect_to(search_path)
      follow_redirect!

      expect(response).to have_http_status(:ok)
      links = sidebar.css("a[data-testid^='nav-']").map { |link| link["data-testid"] }
      expect(links).to eq(%w[nav-search nav-explore])
      expect(sidebar.at_css("[data-testid='nav-guest-badge']").text).to eq("Read-only guest")
      expect(sidebar.at_css("#btn-operator-logout")).to be_present
    end

    it "honours a stored return path only under /search or /graph" do
      get graph_path
      sign_in_guest
      expect(response).to redirect_to(graph_path)

      delete operator_logout_path
      get maintenance_path
      sign_in_guest
      expect(response).to redirect_to(search_path)
    end

    it "signs the guest out on the next request once the toggle is off, and refuses new logins" do
      sign_in_guest
      AppSettings.enable_guest_access = false

      get search_path
      expect(response).to redirect_to(operator_login_path)
      expect(flash[:alert]).to eq("Guest access is disabled.")
      expect(session[:role]).to be_nil

      sign_in_guest
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "signs an existing guest session out after the password changes" do
      sign_in_guest
      enable_guest!(password: "#{guest_password}-rotated")

      get search_path

      expect(response).to redirect_to(operator_login_path)
      expect(flash[:alert]).to eq("Guest access is disabled.")
    end

    it "expires a guest session after 2 hours idle" do
      sign_in_guest
      travel_to((ApplicationController::GUEST_IDLE_TIMEOUT + 1.minute).from_now) do
        get search_path
        expect(response).to redirect_to(operator_login_path)
        expect(flash[:alert]).to eq(I18n.t("operator.sessions.session_expired"))
      end
    end

    it "expires a guest session 24 hours after sign-in, however active" do
      base = Time.current
      sign_in_guest
      (1..12).each do |step|
        travel_to(base + (step * 110).minutes) do
          get search_path
          expect(response).to have_http_status(:ok)
        end
      end
      travel_to(base + ApplicationController::GUEST_ABSOLUTE_TIMEOUT + 1.minute) do
        get search_path
        expect(response).to redirect_to(operator_login_path)
      end
    end

    it "keeps the operator's 24 h idle limit (a guest would have expired at 2 h)" do
      base = Time.current
      sign_in_operator
      travel_to(base + 23.hours) do
        get root_path
        expect(response).to have_http_status(:ok)
      end
      travel_to(base + 23.hours + ApplicationController::SESSION_IDLE_TIMEOUT + 1.minute) do
        get root_path
        expect(response).to redirect_to(operator_login_path)
      end
    end

    it "lets the operator still sign in, and the operator match wins" do
      sign_in_operator
      expect(response).to redirect_to(root_path)
      expect(session[:role]).to eq("operator")
    end

    it "applies the login rate limit to guest attempts" do
      10.times { post operator_session_path, params: { username: "guest", password: "wrong" } }
      sign_in_guest

      expect(response).to have_http_status(:too_many_requests)
    end
  end

  it "accepts a guest password from the credentials only" do
    allow(GraphMem::GuestCredentials).to receive(:credentials_store).and_return({ guest: { password: "cred-only-secret" } })
    GraphMem::GuestCredentials.reset!

    post operator_session_path, params: { username: "guest", password: "cred-only-secret" }

    expect(response).to redirect_to(search_path)
  end

  it "prefers the ENV password over the credentials" do
    allow(GraphMem::GuestCredentials).to receive(:credentials_store).and_return({ guest: { password: "cred-only-secret" } })
    enable_guest!

    post operator_session_path, params: { username: "guest", password: "cred-only-secret" }
    expect(response).to have_http_status(:unprocessable_content)

    sign_in_guest
    expect(response).to redirect_to(search_path)
  end

  it "refuses a guest whose username or password equals the operator's" do
    enable_guest!(username: OperatorAuthHelpers::TEST_OPERATOR_USERNAME)
    post operator_session_path, params: { username: OperatorAuthHelpers::TEST_OPERATOR_USERNAME, password: guest_password }
    expect(response).to have_http_status(:unprocessable_content)

    enable_guest!(password: OperatorAuthHelpers::TEST_OPERATOR_PASSWORD)
    post operator_session_path, params: { username: "guest", password: OperatorAuthHelpers::TEST_OPERATOR_PASSWORD }
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "keeps the production changeme 503 for every sign-in attempt" do
    enable_guest!
    allow(Rails.env).to receive(:production?).and_return(true)
    ENV["OPERATOR_PASSWORD"] = "changeme"

    sign_in_guest

    expect(response).to have_http_status(:service_unavailable)
  end
end
