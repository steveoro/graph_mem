# frozen_string_literal: true

require "rails_helper"

# UI-3 P1/P7: the Search page's query. Synthetic graph; vectors are off unless an example turns
# them on with a stubbed strategy, so nothing reaches an embedding service.
RSpec.describe GraphSearch::Page do
  let!(:alpha) { MemoryEntity.create!(name: "Alpha Service", entity_type: "Project") }
  let!(:gadget) { MemoryEntity.create!(name: "Gadget Project", entity_type: "Project") }
  let!(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component", project_id: alpha.id, aliases: "synth tile|Gizmo") }
  let!(:router) { MemoryEntity.create!(name: "Synth Router", entity_type: "Service", project_id: gadget.id) }
  let!(:parts) do
    Array.new(24) do |i|
      MemoryEntity.create!(name: format("Synth Part %02d", i + 1), entity_type: i.even? ? "Component" : "Note",
                           project_id: i < 12 ? alpha.id : gadget.id)
    end
  end

  def ids(result) = result.rows.map(&:id)

  def tool_ids(**args)
    SearchTool.new.call(per_page: described_class::PER_PAGE, **args)[:results].pluck(:entity_id)
  end

  describe "page = tool" do
    [
      [ {}, {} ],
      [ { "project_id" => :alpha }, { project_id: :alpha } ],
      [ { "types" => [ "Component" ] }, { entity_types: [ "Component" ] } ],
      [ { "match" => [ "", "name" ] }, { search_in_type: false, search_in_aliases: false, search_in_observations: false } ],
      [ { "perspective" => "world", "occurred_after" => "2026-01-01" }, { perspective: "world", occurred_after: "2026-01-01" } ]
    ].each do |page_params, tool_args|
      it "returns the tool's ids in the tool's order on pages 1 and 2 with #{page_params.keys.presence || 'no filters'}" do
        page_params = page_params.transform_values { |value| value == :alpha ? alpha.id.to_s : value }
        tool_args = tool_args.transform_values { |value| value == :alpha ? alpha.id : value }

        [ 1, 2 ].each do |page|
          result = described_class.call({ "q" => "synth", "page" => page.to_s }.merge(page_params))

          expect(result.error).to be_nil
          expect(ids(result)).to eq(tool_ids(query: "synth", page: page, **tool_args)), "page #{page}"
        end
      end
    end

    it "has a full first page and a next page" do
      result = described_class.call({ "q" => "synth" })

      expect(result.rows.size).to eq(described_class::PER_PAGE)
      expect(result).to be_next_page
      expect(described_class.call({ "q" => "synth", "page" => "2" })).not_to be_next_page
    end

    it "ignores the default bucket's context, which would reorder the tool" do
      without = ids(described_class.call({ "q" => "synth" }))
      GraphMemContext.current_project_id = gadget.id

      expect(ids(described_class.call({ "q" => "synth" }))).to eq(without)
      expect(tool_ids(query: "synth")).not_to eq(without)
    end
  end

  describe "modes" do
    let(:vector) { instance_double(VectorSearchStrategy) }

    before do
      allow(EmbeddingService).to receive(:vector_enabled?).and_return(true)
      allow(VectorSearchStrategy).to receive(:new).and_return(vector)
      allow(vector).to receive(:search) { [ VectorSearchStrategy::SearchResult.new(entity: router, distance: 0.2) ] }
      allow(vector).to receive(:search_observations).and_return([])
      allow(EntityRetrievalService).to receive(:search).and_call_original
    end

    it "auto ranks with every channel" do
      result = described_class.call({ "q" => "synth" })

      expect(result.mode).to eq("auto")
      expect(vector).to have_received(:search).at_least(:once)
    end

    it "text makes no embedding call" do
      result = described_class.call({ "q" => "synth", "mode" => "text" })

      expect(result.rows).not_to be_empty
      expect(vector).not_to have_received(:search)
      expect(vector).not_to have_received(:search_observations)
    end

    it "semantic ranks without the text channel" do
      result = described_class.call({ "q" => "synth", "mode" => "semantic" })

      expect(EntityRetrievalService).to have_received(:search).with("synth", hash_including(text: false, ambient_context: false))
      expect(ids(result)).to eq([ router.id ])
    end

    it "falls back from semantic to auto when vectors aren't available" do
      allow(EmbeddingService).to receive(:vector_enabled?).and_return(false)

      result = described_class.call({ "q" => "synth", "mode" => "semantic" })

      expect(result.mode).to eq("auto")
      expect(result.semantic_available).to be(false)
    end

    it "maps the old ?strategy= values and treats unknown modes as auto" do
      expect(described_class.call({ "q" => "x", "strategy" => "text" }).mode).to eq("text")
      expect(described_class.call({ "q" => "x", "strategy" => "vector" }).mode).to eq("semantic")
      expect(described_class.call({ "q" => "x", "mode" => "bogus" }).mode).to eq("auto")
    end
  end

  describe "exact mode" do
    it "matches the name or one whole alias, case-insensitively, by name" do
      expect(ids(described_class.call({ "q" => "synthwidget", "mode" => "exact" }))).to eq([ widget.id ])
      expect(ids(described_class.call({ "q" => "Synth Tile", "mode" => "exact" }))).to eq([ widget.id ])
      expect(ids(described_class.call({ "q" => "synth", "mode" => "exact" }))).to eq([])
      expect(described_class.call({ "q" => "gizmo", "mode" => "exact" }).rows.sole.matched_fields).to eq([ "aliases" ])
    end

    it "keeps to the project and type filters" do
      expect(ids(described_class.call({ "q" => "SynthWidget", "mode" => "exact", "project_id" => gadget.id.to_s }))).to eq([])
      expect(ids(described_class.call({ "q" => "SynthWidget", "mode" => "exact", "types" => [ "Component" ] }))).to eq([ widget.id ])
    end
  end

  describe "filters" do
    it "maps match[] to the search_in_* flags; absent means all on" do
      allow(GraphSearch).to receive(:call).and_return(results: [])

      described_class.call({ "q" => "synth" })
      expect(GraphSearch).to have_received(:call).with(hash_excluding(:search_in_name))

      described_class.call({ "q" => "synth", "match" => [ "", "aliases", "observations" ] })
      expect(GraphSearch).to have_received(:call).with(hash_including(
        search_in_name: false, search_in_aliases: true, search_in_type: false, search_in_observations: true
      ))
    end

    it "reports invalid filters and dates as the error" do
      expect(described_class.call({ "q" => "synth", "project_id" => widget.id.to_s }).error)
        .to eq("project_id must be the id of a Project entity.")
      expect(described_class.call({ "q" => "synth", "occurred_after" => "someday" }).error)
        .to eq('invalid temporal bound (expected ISO 8601): "someday"')
      expect(described_class.call({ "q" => "synth", "match" => [ "" ] }).error)
        .to eq("At least one search field (name, type, aliases, observations) must be enabled.")
    end

    it "drops blank form values" do
      result = described_class.call({ "q" => "synth", "project_id" => "", "types" => [ "" ], "perspective" => "" })

      expect(result.error).to be_nil
      expect(result.filters).to include(project_id: nil, types: [], perspective: nil, match: nil)
    end
  end

  describe "rows" do
    before do
      widget.memory_observations.create!(content: "SynthWidget renders synthetic tiles", perspective: "world")
      widget.memory_observations.create!(content: "Tiles were cached", perspective: "experience")
      widget.memory_observations.create!(content: "Old synth tile notes", status: "obsolete", obsoleted_at: Time.current)
      widget.memory_observations.create!(content: "Unrelated text")
      MemoryRelation.create!(from_entity: widget, to_entity: router, relation_type: "depends_on")
      MemoryRelation.create!(from_entity: parts.first, to_entity: widget, relation_type: "depends_on")
    end

    def row_for(result, entity) = result.rows.find { |row| row.id == entity.id }

    it "carries up to two snippets by token overlap, the project name and the relation count" do
      row = row_for(described_class.call({ "q" => "synth tiles", "mode" => "text" }), widget)

      expect(row.snippets.map(&:content)).to eq([ "SynthWidget renders synthetic tiles", "Tiles were cached" ])
      expect(row.project_name).to eq("Alpha Service")
      expect(row.relation_count).to eq(2)
    end

    it "applies the perspective to snippets and shows obsolete ones only when asked" do
      world = row_for(described_class.call({ "q" => "synth tiles", "mode" => "text", "perspective" => "world" }), widget)
      expect(world.snippets.map(&:content)).to eq([ "SynthWidget renders synthetic tiles" ])

      obsolete = row_for(described_class.call({ "q" => "synth tile notes", "mode" => "text", "include_obsolete" => "1" }), widget)
      expect(obsolete.snippets.map(&:content)).to include("Old synth tile notes")
      active_only = row_for(described_class.call({ "q" => "synth tile notes", "mode" => "text" }), widget)
      expect(active_only.snippets.map(&:content)).not_to include("Old synth tile notes")
    end

    it "loads every snippet with one query and makes no embedding call" do
      allow(EmbeddingService.instance).to receive(:embed).and_raise("embedding called")
      observation_queries = []
      callback = ->(*, payload) { observation_queries << payload[:sql] if payload[:sql].match?(/FROM `memory_observations`/) }

      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        described_class.call({ "q" => "synth tiles", "mode" => "text" })
      end

      expect(observation_queries.size).to eq(1)
    end
  end
end
