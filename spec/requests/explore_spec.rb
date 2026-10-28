# frozen_string_literal: true

require "rails_helper"

# UI-4b E2: the Explore page (operator and guest) and the /graph redirect. Synthetic data.
RSpec.describe "Explore page", type: :request do
  let!(:alpha) { MemoryEntity.create!(name: "Alpha Service", entity_type: "Project") }
  let!(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component", project_id: alpha.id) }

  def html = Nokogiri::HTML(response.body)
  def root_data = html.at_css("[data-controller='explore']")

  it "renders the canvas, toolbar and panel frame for the operator" do
    sign_in_operator

    get explore_path

    expect(response).to have_http_status(:ok)
    expect(root_data["data-explore-read-only-value"]).to eq("false")
    expect(root_data["data-explore-scope-value"]).to eq("root")
    expect(html.at_css("[data-explore-target='canvas']")).to be_present
    expect(html.at_css("turbo-frame#entity-panel")).to be_present
    expect(html.css("#explore-scope option").map { |option| option["value"] }).to include("root", "full", "project:#{alpha.id}")
    expect(html.css("#explore-type-filter option").map(&:text)).to include("Component", "Project")
    expect(html.css("#explore-layout option").map { |option| option["value"] }).to eq(%w[cose breadthfirst concentric grid])
    expect(html.at_css("[data-testid='explore-search-link']")["href"]).to eq(search_path)
    expect(html.at_css("form[data-testid='search-form']")).to be_nil
    expect(html.css("script:not([src])").map(&:text).join).not_to include("SynthWidget")
  end

  it "serves the guest read-only" do
    enable_guest!
    sign_in_guest

    get explore_path(entity_id: widget.id)

    expect(response).to have_http_status(:ok)
    expect(root_data["data-explore-read-only-value"]).to eq("true")
    expect(root_data["data-explore-scope-value"]).to eq("entity")
  end

  it "sends a signed-out visitor to the login page" do
    get explore_path

    expect(response).to redirect_to(operator_login_path)
  end

  {
    { project_id: "PROJECT" } => [ "project", "data-explore-project-id-value" ],
    { entity_id: "WIDGET", depth: "2" } => [ "entity", "data-explore-entity-id-value" ],
    { scoped_entity_id: "WIDGET" } => [ "entity", "data-explore-entity-id-value" ],
    { ids: "WIDGET,PROJECT" } => [ "search", "data-explore-ids-value" ],
    { scope: "full" } => [ "full", nil ]
  }.each do |params, (scope, attribute)|
    it "starts on the #{scope} scope for #{params.keys.join(', ')}" do
      sign_in_operator
      ids = { "PROJECT" => alpha.id.to_s, "WIDGET" => widget.id.to_s }
      resolved = params.transform_values { |value| value.gsub(/PROJECT|WIDGET/, ids) }

      get explore_path(resolved)

      expect(root_data["data-explore-scope-value"]).to eq(scope)
      expect(root_data[attribute]).to be_present if attribute
      expect(root_data["data-explore-depth-value"]).to eq(params[:depth] || "1")
    end
  end

  [ { entity_id: "abc" }, { entity_id: "0" }, { project_id: "-3" }, { ids: "1,,2" }, { ids: (1..101).to_a.join(",") },
    { depth: "9", entity_id: "x" }, { scope: "<script>" } ].each do |params|
    it "falls back to the root view for #{params.inspect.truncate(40)}" do
      sign_in_operator

      get explore_path(params)

      expect(response).to have_http_status(:ok)
      expect(root_data["data-explore-scope-value"]).to eq("root")
      expect(root_data["data-explore-entity-id-value"]).to be_nil
    end
  end

  it "redirects /graph (with its query string) to /explore with 301" do
    get "/graph?ids=1,2"
    expect(response).to have_http_status(:moved_permanently)
    expect(response.headers["Location"]).to end_with("/explore?ids=1,2")

    get "/graph"
    expect(response).to have_http_status(:moved_permanently)
    expect(response.headers["Location"]).to end_with("/explore")

    get "/graph?scoped_entity_id=#{widget.id}"
    expect(response.headers["Location"]).to end_with("/explore?scoped_entity_id=#{widget.id}")
  end
end
