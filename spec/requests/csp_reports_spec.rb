# frozen_string_literal: true

require "rails_helper"

RSpec.describe "CSP violation reports", type: :request do
  let(:csp_violation_payload) do
    {
      "csp-report" => {
        "document-uri"        => "https://example.com/",
        "blocked-uri"         => "https://evil.example.com/script.js",
        "violated-directive"  => "script-src",
        "original-policy"     => "default-src 'self'"
      }
    }.to_json
  end

  describe "POST /csp-reports" do
    it "returns 204 No Content without requiring sign-in" do
      post "/csp-reports",
           params:  csp_violation_payload,
           headers: { "Content-Type" => "application/csp-report" }

      expect(response).to have_http_status(:no_content)
    end

    it "accepts an empty body" do
      post "/csp-reports",
           headers: { "Content-Type" => "application/csp-report" }

      expect(response).to have_http_status(:no_content)
    end
  end

  describe "eager loading" do
    it "CspReportsController can be referenced without NameError" do
      # Verifies that removing skip_forgery_protection (which does not exist on
      # ActionController::API) means the class loads without a NameError.
      expect { CspReportsController }.not_to raise_error
    end
  end
end
