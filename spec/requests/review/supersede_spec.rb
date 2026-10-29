# frozen_string_literal: true

require "rails_helper"

# Fact supersede F5: Find & supersede (operator only). Synthetic data only.
RSpec.describe "Review › Find & supersede", type: :request do
  let!(:gadget) { fs_project!("Gadget Project") }
  let!(:widget) { fs_member!(gadget, "SynthWidget") }
  let!(:legacy) { fs_project!("Legacy Gadget") }
  let!(:legacy_widget) { fs_member!(legacy, "Legacy SynthWidget") }
  let!(:fact) { fs_fact!(gadget, tags: [ "replaces:fast-mcp" ]) }

  def listed = Nokogiri::HTML(response.body).css("[data-testid='supersede-row']").map { |row| row["data-observation-id"].to_i }

  def bulk(ids, **params)
    post review_supersede_path, params: { project_id: gadget.id, observation_ids: ids, bulk_action: "retire" }.merge(params)
  end

  context "as the operator" do
    before { sign_in_operator }

    it "asks for a project first, and searches one project with % and _ escaped" do
      get review_supersede_path
      expect(response.body).to include('data-testid="supersede-missing"', "Choose a project")

      done = fs_observe!(widget, "SynthWidget is 100% done.")
      fs_observe!(widget, "SynthWidget has 1000 rows.")
      underscored = fs_observe!(widget, "SynthWidget uses a_b.")
      fs_observe!(widget, "SynthWidget uses axb.")
      fs_observe!(legacy_widget, "Legacy is 100% done.")

      get review_supersede_path(project_id: gadget.id, q: "100%")
      expect(listed).to eq([ done.id ])
      get review_supersede_path(project_id: gadget.id, q: "a_b")
      expect(listed).to eq([ underscored.id ])
    end

    it "lists all projects view-only, and inactive rows only when asked (never selectable)" do
      ours = fs_observe!(widget, "The MCP server runs on fast-mcp.")
      theirs = fs_observe!(legacy_widget, "The MCP server runs on fast-mcp.")
      retired = fs_observe!(widget, "The old fast-mcp transport.").tap(&:mark_obsolete!)

      get review_supersede_path(project_id: "all", q: "fast-mcp")
      expect(listed).to contain_exactly(ours.id, theirs.id)
      expect(response.body).to include('data-testid="supersede-view-only"')
      expect(response.body).not_to include('data-testid="supersede-actions"', 'name="observation_ids[]"')

      get review_supersede_path(project_id: gadget.id, q: "fast-mcp", include_inactive: "1")
      expect(listed).to contain_exactly(ours.id, retired.id)
      expect(response.body).not_to include("value=\"#{retired.id}\"")
    end

    it "with a fact: shows the candidates, the guard and the pending verdict, and says similarity is off" do
      old = fs_observe!(widget, "The MCP server runs on fast-mcp.")
      kept = fs_observe!(widget, "Legacy Gadget still runs on fast-mcp.")
      FactSupersedeJob.perform_now(fact.id)

      get review_supersede_path(project_id: gadget.id, fact_id: fact.id)

      expect(listed).to contain_exactly(old.id, kept.id)
      expect(response.body).to include('data-testid="supersede-vector-off"', "unjudged", ">keep<")
      expect(response.body).not_to include("value=\"#{kept.id}\"")
    end

    it "retires three rows in one change set, and undo restores all three" do
      rows = Array.new(3) { |i| fs_observe!(widget, "The MCP server runs on fast-mcp, take #{i}.") }

      bulk(rows.map(&:id), fact_id: fact.id)

      expect(response).to redirect_to(review_supersede_path(project_id: gadget.id, fact_id: fact.id))
      expect(rows.map { |row| row.reload.attributes.values_at("status", "outdated_by_id") }).to all(eq([ "obsolete", fact.id ]))
      set = ChangeSet.find_by!(kind: "explore.bulk_supersede")
      expect(flash[:undo]).to include("uuid" => set.uuid)

      post undo_change_path(set.uuid), headers: { "HTTP_REFERER" => review_supersede_path }
      expect(rows.map { |row| row.reload.attributes.values_at("status", "outdated_by_id") }).to all(eq([ "active", nil ]))
    end

    it "supersedes with one text or the fact's text, and skips rows outside the project, inactive or changed" do
      first = fs_observe!(widget, "The MCP server runs on fast-mcp.")
      second = fs_observe!(widget, "SynthWidget talks to fast-mcp.")
      foreign = fs_observe!(legacy_widget, "The MCP server runs on fast-mcp.")
      inactive = fs_observe!(widget, "fast-mcp was here.").tap(&:mark_obsolete!)
      rendered_at = Time.current.utc.iso8601(6)
      second.update_active!(content: "SynthWidget talks to fast-mcp 1.6.")

      bulk([ first.id, second.id, foreign.id, inactive.id ], bulk_action: "supersede", use_fact_text: "1", fact_id: fact.id, rendered_at: rendered_at)

      expect(flash[:notice]).to eq("Superseded 1 observation. 1 skipped: no longer active; 1 skipped: not in the project; 1 skipped: changed since you looked.")
      expect(first.reload.superseded_by.content).to eq(fact.content)
      expect([ foreign, second ].map { |row| row.reload.status }).to all(eq("active"))

      bulk([ second.id ], bulk_action: "supersede", replacement: "SynthWidget talks to the mcp gem.")
      expect(second.reload.superseded_by.content).to eq("SynthWidget talks to the mcp gem.")
    end

    it "refuses 201 rows, a missing replacement and all projects with 422" do
      bulk((1..201).to_a)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("at most 200")

      bulk([ fs_observe!(widget, "fast-mcp.").id ], bulk_action: "supersede")
      expect(response).to have_http_status(:unprocessable_content)

      post review_supersede_path, params: { project_id: "all", observation_ids: [ 1 ], bulk_action: "retire" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(ChangeSet.count).to eq(0)
    end

    it "links Find what this outdates from the fact's panel row" do
      get entity_panel_path(gadget)

      expect(response.body).to include('data-testid="entity-panel-find-outdated"', review_supersede_path(project_id: gadget.id, fact_id: fact.id).gsub("&", "&amp;"))
    end
  end

  it "answers a guest with 403 on both routes, and sends a signed-out visitor to sign in" do
    get review_supersede_path
    expect(response).to redirect_to(operator_login_path)

    enable_guest!
    sign_in_operator(username: "guest", password: OperatorAuthHelpers::TEST_GUEST_PASSWORD)
    get review_supersede_path(project_id: gadget.id, q: "fast-mcp")
    expect(response).to have_http_status(:forbidden)
    post review_supersede_path, params: { project_id: gadget.id, observation_ids: [ fact.id ], bulk_action: "retire" }
    expect(response).to have_http_status(:forbidden)
    expect(fact.reload).to be_active
  end
end
