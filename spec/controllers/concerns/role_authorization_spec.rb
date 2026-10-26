# frozen_string_literal: true

require "rails_helper"

# mcp plan PR-2 §2.20 item 7: allow_guest appends, and never mutates a parent class.
RSpec.describe RoleAuthorization do
  let(:parent) { Class.new { include RoleAuthorization } }

  it "keeps the actions from every allow_guest call" do
    parent.allow_guest :index
    parent.allow_guest :show, :index

    expect(parent._guest_allowed_actions).to eq(%w[index show])
  end

  it "lets a subclass add an action without changing its parent" do
    parent.allow_guest :index
    child = Class.new(parent) { allow_guest :results }

    expect(child._guest_allowed_actions).to eq(%w[index results])
    expect(parent._guest_allowed_actions).to eq(%w[index])
  end
end

RSpec.describe "RoleAuthorization#authorize_role!", type: :controller do
  render_views

  controller(ApplicationController) do
    allow_guest :index

    def index = render(plain: "index")
    def show = render(plain: "show")
  end

  before do
    routes.draw do
      get "index" => "anonymous#index"
      get "show" => "anonymous#show"
    end
    session[:signed_in_at] = session[:last_seen_at] = Time.current.to_i
  end

  def sign_in_as(role)
    session[:role] = role
    session[:user] = role
    return unless role == "guest"

    allow(GraphMem::GuestCredentials).to receive(:current).and_return(
      GraphMem::GuestCredentials.new(username: "guest", password: "synthetic-guest-secret")
    )
    session[:guest_cred_fp] = GraphMem::GuestCredentials.current.fingerprint
  end

  it "lets the operator into every action" do
    sign_in_as("operator")

    get :show
    expect(response.body).to eq("show")
  end

  it "lets a guest into an opted-in action" do
    sign_in_as("guest")

    get :index
    expect(response.body).to eq("index")
  end

  it "answers a guest with the 403 page elsewhere" do
    sign_in_as("guest")

    get :show
    expect(response).to have_http_status(:forbidden)
    expect(response.body).to include('data-testid="guest-forbidden"')
  end

  it "answers a guest JSON request with 403 JSON" do
    sign_in_as("guest")

    get :show, format: :json
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body).to eq("error" => "forbidden", "role" => "guest")
  end
end
