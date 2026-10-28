# frozen_string_literal: true

require "rails_helper"

# UI-3 P4: the read-only entity panel. Synthetic data only.
RSpec.describe "Entity panel", type: :request do
  let!(:alpha) { MemoryEntity.create!(name: "Alpha Service", entity_type: "Project") }
  let!(:widget) do
    MemoryEntity.create!(name: "SynthWidget", entity_type: "Component", project_id: alpha.id, aliases: "synth tile",
                         description: "Renders synthetic tiles")
  end
  let!(:router) { MemoryEntity.create!(name: "Synth Router", entity_type: "Service") }
  let(:frame) { { "Turbo-Frame" => "entity-panel" } }

  before do
    MemoryRelation.create!(from_entity: widget, to_entity: router, relation_type: "depends_on")
    MemoryRelation.create!(from_entity: router, to_entity: widget, relation_type: "calls")
    # trust_score is computed on save (and again when a relation is added); set it last.
    widget.memory_observations.create!(content: "Low-trust note").update_column(:trust_score, 0.2)
    widget.memory_observations.create!(content: "High-trust fact").update_column(:trust_score, 0.9)
    widget.memory_observations.create!(content: "Retired fact", status: "obsolete", obsoleted_at: Time.current)
  end

  def html = Nokogiri::HTML(response.body)
  def observations = html.css("[data-testid='entity-panel-observation']").map { |item| item.at_css("span").text }

  shared_examples "a read-only panel" do
    it "shows the entity, its observations by trust and its relations, with no form or edit link" do
      get entity_panel_path(widget), headers: frame

      expect(response).to have_http_status(:ok)
      expect(html.at_css("turbo-frame#entity-panel h2").text).to eq("SynthWidget")
      expect(response.body).to include("Alpha Service", "synth tile", "Renders synthetic tiles")
      expect(observations).to eq([ "High-trust fact", "Low-trust note" ])
      expect(html.css("[data-testid='entity-panel-relation']").map { |link| [ link.text, link["href"] ] })
        .to eq([ [ "Synth Router", entity_panel_path(router) ], [ "Synth Router", entity_panel_path(router) ] ])
      expect(html.at_css("[data-testid='entity-panel-explore']")["href"]).to eq(graph_path(scoped_entity_id: widget.id))
      expect(html.css("form")).to be_empty
      expect(html.css("a").map { |link| link["href"] }).to all(satisfy { |href| !href.to_s.match?(%r{/edit|/operator/}) })
      expect(html.at_css("ui-sidebar, nav.ui-sidebar")).to be_nil # no layout inside a frame request
    end

    it "toggles obsolete observations" do
      get entity_panel_path(widget), headers: frame
      expect(html.at_css("[data-testid='entity-panel-obsolete-toggle']").text).to eq("Show 1 obsolete")

      get entity_panel_path(widget, obsolete: "1"), headers: frame
      expect(observations).to include("Retired fact")
      expect(html.at_css("[data-testid='entity-panel-obsolete-toggle']").text).to eq("Hide obsolete")
    end

    it "pages observations ten at a time" do
      11.times { |i| widget.memory_observations.create!(content: "Fact #{i}") }

      get entity_panel_path(widget), headers: frame
      expect(observations.size).to eq(10)
      expect(html.at_css("a[href='#{entity_panel_path(widget, page: 2)}']")).to be_present

      get entity_panel_path(widget, page: 2), headers: frame
      expect(observations.size).to eq(3)
    end

    it "answers 404 for an unknown entity" do
      get entity_panel_path(id: 0), headers: frame

      expect(response).to have_http_status(:not_found)
      expect(html.at_css("[data-testid='entity-panel-missing']")).to be_present
    end

    it "renders as a page in the layout outside a frame" do
      get entity_panel_path(widget)

      expect(response).to have_http_status(:ok)
      expect(html.at_css("nav.ui-sidebar")).to be_present
    end
  end

  context "as the operator" do
    before { sign_in_operator }

    it_behaves_like "a read-only panel"

    it "links to Review for the entity" do
      get entity_panel_path(widget), headers: frame

      expect(html.at_css("[data-testid='entity-panel-review']")["href"]).to eq(review_path(q: "SynthWidget"))
    end
  end

  context "as a guest" do
    before do
      enable_guest!
      sign_in_guest
    end

    it_behaves_like "a read-only panel"

    it "has no Open in Review link" do
      get entity_panel_path(widget), headers: frame

      expect(response).to have_http_status(:ok)
      expect(html.at_css("[data-testid='entity-panel-review']")).to be_nil
      expect(response.body).not_to include(review_path)
    end
  end

  context "when signed out" do
    it "sends the visitor to sign in" do
      get entity_panel_path(widget)

      expect(response).to redirect_to(operator_login_path)
    end
  end
end
