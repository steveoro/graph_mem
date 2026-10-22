# frozen_string_literal: true

require "rails_helper"

RSpec.describe "/api-docs (Rswag)", type: :request do
  describe "GET /api-docs" do
    context "without an operator session" do
      it "returns 404 (route constraint not matched)" do
        get "/api-docs/index.html"
        # OperatorSessionConstraint failing causes the mount to be skipped → 404
        expect(response).to have_http_status(:not_found)
      end
    end

    context "with an operator session" do
      it "allows access" do
        sign_in_operator
        get "/api-docs/index.html"
        # Rswag serves its UI; 200 or 301 redirect to the index are both acceptable
        expect(response.status).to be_between(200, 302)
      end
    end
  end
end
