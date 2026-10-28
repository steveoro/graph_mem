# frozen_string_literal: true

require "rails_helper"

# UI-3: the Search page (GET /search) for the operator and the guest. Synthetic data; vectors
# are off in specs, so Semantic is shown as unavailable.
RSpec.describe "Search page", type: :request do
  let!(:alpha) { MemoryEntity.create!(name: "Alpha Service", entity_type: "Project") }
  let!(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component", project_id: alpha.id) }
  let!(:router) { MemoryEntity.create!(name: "Synth Router", entity_type: "Service") }

  def html = Nokogiri::HTML(response.body)
  def result_names = html.css("[data-testid='search-result-link']").map(&:text)

  before { sign_in_operator }

  it "shows the prompt and no results for a blank query" do
    get search_path

    expect(response).to have_http_status(:ok)
    expect(html.css("[data-testid='search-result']")).to be_empty
    expect(response.body).to include("Type a query to search the graph.")
    expect(html.at_css("form[data-testid='search-form']")["method"]).to eq("get")
  end

  it "lists results with breadcrumb, panel links and the Explore link" do
    get search_path, params: { q: "synth" }

    expect(result_names).to contain_exactly("SynthWidget", "Synth Router")
    row = html.at_css("[data-testid='search-result'][data-entity-id='#{widget.id}']")
    expect(row.at_css("[data-testid='search-result-crumb']").text.strip).to eq("Alpha Service")
    link = row.at_css("[data-testid='search-result-link']")
    expect(link["href"]).to eq(entity_panel_path(widget))
    expect(link["data-turbo-frame"]).to eq("entity-panel")
    expect(row.at_css("a[href='#{graph_path(scoped_entity_id: widget.id)}']")).to be_present
    expect(html.at_css("turbo-frame#entity-panel")).to be_present
  end

  it "runs each mode" do
    { "auto" => 2, "text" => 2, "exact" => 0 }.each do |mode, count|
      get search_path, params: { q: "synth", mode: mode }

      expect(response).to have_http_status(:ok)
      expect(result_names.size).to eq(count), mode
      expect(html.at_css("[data-testid='search-mode-#{mode}']")["checked"]).to eq("checked")
    end

    get search_path, params: { q: "SynthWidget", mode: "exact" }
    expect(result_names).to eq([ "SynthWidget" ])
  end

  it "keeps the filters in the form and in the paging links" do
    24.times { |i| MemoryEntity.create!(name: "Synth Part #{i}", entity_type: "Component", project_id: alpha.id) }

    get search_path, params: { q: "synth", project_id: alpha.id, types: [ "Component" ], match: [ "", "name" ], mode: "text" }

    expect(html.at_css("#search-project option[selected]")["value"]).to eq(alpha.id.to_s)
    expect(html.at_css("input[name='types[]'][value='Component']")["checked"]).to eq("checked")
    expect(html.css("input[name='match[]'][checked]").map { |box| box["value"] }).to eq([ "name" ])
    next_href = html.at_css("[data-testid='search-next']")["href"]
    expect(Rack::Utils.parse_nested_query(URI(next_href).query)).to eq(
      "q" => "synth", "mode" => "text", "project_id" => alpha.id.to_s, "types" => [ "Component" ], "match" => [ "name" ], "page" => "2"
    )

    get next_href
    expect(html.at_css("[data-testid='search-prev']")).to be_present
  end

  {
    { project_id: "abc" } => "project_id must be the id of a Project entity.",
    { types: Array.new(21) { |i| "Type#{i}" } } => "entity_types must be a list of 1 to 20 non-blank entity types.",
    { occurred_after: "someday" } => 'invalid temporal bound (expected ISO 8601): "someday"',
    { as_of: "2026-08-15", occurred_after: "2026-08-01" } => "as_of cannot be combined with occurred_after/occurred_before",
    { match: [ "" ] } => "At least one search field (name, type, aliases, observations) must be enabled."
  }.each do |params, message|
    it "answers 422 with the message for #{params.keys.join(', ')}" do
      get search_path, params: { q: "synth" }.merge(params)

      expect(response).to have_http_status(:unprocessable_content)
      expect(html.at_css("[data-testid='search-error']").text).to include(message)
    end
  end

  it "refuses a page past MAX_PAGE and an over-long query with 422 (guest-reachable bounds)" do
    get search_path, params: { q: "synth", page: GraphSearch::Page::MAX_PAGE + 1 }
    expect(response).to have_http_status(:unprocessable_content)
    expect(html.at_css("[data-testid='search-error']").text).to include("page must be between 1 and 50.")

    get search_path, params: { q: "s" * (GraphSearch::Page::MAX_QUERY_LENGTH + 1) }
    expect(response).to have_http_status(:unprocessable_content)
    expect(html.at_css("[data-testid='search-error']").text).to include("The query must be at most 500 characters.")

    get search_path, params: { q: "s" * GraphSearch::Page::MAX_QUERY_LENGTH }
    expect(response).to have_http_status(:ok)
  end

  %w[0 -3 abc].each do |page|
    it "renders page 1 for page=#{page}" do
      get search_path, params: { q: "synth", page: page }

      expect(response).to have_http_status(:ok)
      expect(result_names.first).to eq(GraphSearch::Page.call({ "q" => "synth" }).rows.first.entity.name)
      expect(html.at_css("[data-testid='search-prev']")).to be_nil
    end
  end

  it "shows no Next link on the last allowed page" do
    allow(GraphSearch).to receive(:call).and_return(results: Array.new(20) { |i| { entity_id: widget.id, relevance_score: 1.0 - (i / 100.0), matched_fields: [ "name" ] } })

    get search_path, params: { q: "synth", page: GraphSearch::Page::MAX_PAGE }

    expect(response).to have_http_status(:ok)
    expect(html.at_css("[data-testid='search-next']")).to be_nil
    expect(html.at_css("[data-testid='search-prev']")).to be_present
  end

  it "treats LIKE wildcards in an Exact query literally" do
    MemoryEntity.create!(name: "Synth Dial", entity_type: "Component", aliases: "dial|knob")

    %w[% _ %_%].each do |query|
      get search_path, params: { q: query, mode: "exact" }

      expect(response).to have_http_status(:ok)
      expect(result_names).to eq([]), query
    end
  end

  it "disables the unticked type chips once the 20-type cap is reached" do
    types = Array.new(SearchFilter::MAX_ENTITY_TYPES) { |i| "Type#{i}" }

    get search_path, params: { q: "synth", types: types }

    expect(response).to have_http_status(:ok)
    chips = html.css("input[name='types[]']")
    expect(chips.select { |chip| chip["checked"] }.size).to eq(20)
    expect(chips.reject { |chip| chip["checked"] }).to all(satisfy { |chip| chip["disabled"] == "disabled" })
    expect(chips.reject { |chip| chip["checked"] }).not_to be_empty
    expect(html.at_css("[data-testid='search-form'] summary").text).to include("(up to 20)")
  end

  it "treats an unknown mode as auto and explains why Semantic is off" do
    get search_path, params: { q: "synth", mode: "bogus" }

    expect(html.at_css("[data-testid='search-mode-auto']")["checked"]).to eq("checked")
    expect(html.at_css("[data-testid='search-mode-semantic']")["disabled"]).to eq("disabled")
    expect(html.at_css("[data-testid='search-semantic-unavailable']").text).to include("isn't available")
  end

  it "still answers the old /search?q=&strategy= links" do
    %w[text vector].each do |strategy|
      get search_path, params: { q: "synth", strategy: strategy }

      expect(response).to have_http_status(:ok)
      expect(result_names).to contain_exactly("SynthWidget", "Synth Router")
    end
  end

  describe "escaping" do
    let!(:tagged) { MemoryEntity.create!(name: "<b>Synth</b>Widget", entity_type: "Component", description: "Tom & Jerry amp") }

    before { MemoryObservation.create!(memory_entity: widget, content: "<script>synth()</script> renders tiles") }

    it "escapes names and snippets and marks only the tokens" do
      get search_path, params: { q: "synth" }

      expect(response.body).to include("&lt;b&gt;Synth&lt;/b&gt;Widget")
      expect(response.body).not_to include("<b>Synth</b>")
      expect(response.body).not_to include("<script>synth()</script>")
      snippet = html.at_css("[data-testid='search-result'][data-entity-id='#{widget.id}'] [data-testid='search-snippet']")
      expect(snippet.inner_html).to include("&lt;script&gt;<mark>synth</mark>()&lt;/script&gt;")
      expect(html.css("main script")).to be_empty
    end

    it "never matches a token inside an escaped entity" do
      get search_path, params: { q: "<b>Synth</b>Widget amp", mode: "text" }
      description = html.at_css("[data-testid='search-result'][data-entity-id='#{tagged.id}'] .search-result__snippet")
      expect(description.inner_html).to eq("Tom &amp; Jerry <mark>amp</mark>")
    end
  end

  it "links Show as graph to this page's ids" do
    get search_path, params: { q: "synth" }

    ids = html.css("[data-testid='search-result']").map { |row| row["data-entity-id"] }
    expect(html.at_css("[data-testid='search-show-graph']")["href"]).to eq(graph_path(ids: ids.join(",")))

    get search_path, params: { q: "nothing-matches-this" }
    expect(html.at_css("[data-testid='search-show-graph']")).to be_nil
  end

  context "as a guest" do
    before do
      enable_guest!
      sign_in_guest
    end

    it "gets the same results, the panel links and Show as graph" do
      get search_path, params: { q: "synth" }

      expect(response).to have_http_status(:ok)
      expect(result_names).to contain_exactly("SynthWidget", "Synth Router")
      expect(html.at_css("[data-testid='search-show-graph']")).to be_present
    end
  end
end
