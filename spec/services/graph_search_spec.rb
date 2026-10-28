# frozen_string_literal: true

require "rails_helper"

# UI-3 S1 gate: what the `search` tool returns today, recorded against the unchanged
# SearchTool#call before GraphSearch was extracted from it. These examples are never edited:
# with the new arguments omitted, the output must stay exactly this. Synthetic graph only; the
# two vector channels are stubbed with fixed results, so nothing reaches an embedding service.
RSpec.describe "GraphSearch" do
  subject(:tool) { SearchTool.new }

  let(:old) { Time.utc(2025, 3, 1, 12) }

  let!(:alpha) { MemoryEntity.create!(name: "Alpha Service", entity_type: "Project") }
  let!(:gadget) { MemoryEntity.create!(name: "Gadget Project", entity_type: "Project") }
  let!(:entities) do
    {
      widget: entity("SynthWidget", "Component", alpha, aliases: "synth tile|widget"),
      gauge: entity("Synth Gauge", "Component", alpha),
      router: entity("Synth Router", "Service", gadget, aliases: "synth-router"),
      dial: entity("SynthDial", "Feature", gadget),
      ledger: entity("Synth Ledger", "Note", nil),
      guide: entity("Calibration Guide", "Note", alpha, aliases: "synth calibration"),
      relay: entity("Relay Board", "Component", gadget, description: "Board of synth relays"),
      hub: entity("Sensor Hub", "Service", alpha),
      probe: entity("Thermo Probe", "Sensor", nil),
      signal: entity("Signal Box", "Feature", gadget, aliases: "sensor box"),
      rig: entity("Bench Rig", "Tool", nil)
    }.merge(
      (1..18).to_h do |i|
        [ :"part#{i}", entity(format("Synth Part %02d", i), i.even? ? "Component" : "Note", i <= 9 ? alpha : gadget) ]
      end
    )
  end

  # Fixed semantic channels: entity vectors and observation vectors, perspective-aware.
  let(:vector) { instance_double(VectorSearchStrategy) }
  let(:entity_vector_names) { [ "SynthWidget", "Calibration Guide", "Relay Board", "Synth Router", "Alpha Service" ] }
  let(:observation_vector_names) do
    { nil => [ "Relay Board", "Synth Gauge", "SynthDial", "Calibration Guide" ],
      "world" => [ "Synth Gauge", "Relay Board" ],
      "experience" => [ "SynthDial", "Calibration Guide" ] }
  end

  def entity(name, type, project, **attrs)
    MemoryEntity.create!(name: name, entity_type: type, project_id: project&.id, **attrs)
  end

  def observe(key, content, **attrs)
    target = key.is_a?(Symbol) ? entities.fetch(key) : key
    MemoryObservation.create!(memory_entity: target, content: content, created_at: old, updated_at: old, **attrs)
  end

  def by_name(name) = MemoryEntity.find_by!(name: name)

  def names(rows) = rows.map { |row| MemoryEntity.find(row[:entity_id]).name }

  # No two ranked entities may tie on their unrounded fused score: the sort isn't stable, so a
  # tie would make the order depend on hash insertion and the gate would be meaningless.
  def expect_no_ties
    expect(@fused_scores).to be_present
    expect(@fused_scores).to eq(@fused_scores.uniq)
  end

  before do
    observe(:widget, "SynthWidget renders synthetic tiles", perspective: "world")
    observe(:widget, "Tuned the SynthWidget tile cache in October", perspective: "experience",
                     valid_from: Time.utc(2026, 10, 5), valid_until: Time.utc(2026, 10, 6))
    observe(:gauge, "Synth Gauge reads the synthetic pressure", perspective: "world",
                    valid_from: Time.utc(2026, 10, 12))
    observe(:router, "Synth Router forwards synthetic packets", valid_from: Time.utc(2025, 1, 1), valid_until: Time.utc(2025, 12, 31))
    observe(:dial, "Turned the dial during the October synthetic drill", perspective: "experience",
                   valid_from: Time.utc(2026, 10, 20))
    observe(:relay, "Relay Board switches the synth relays", perspective: "world", valid_from: Time.utc(2026, 9, 15))
    observe(:guide, "Calibration steps for synthetic sensors", perspective: "experience")
    observe(:ledger, "Synth Ledger notes are obsolete", status: "obsolete", obsoleted_at: old)
    observe(:part3, "Part three was replaced in October 2026", valid_from: Time.utc(2026, 10, 2))
    observe(:rig, "Bench Rig hosts the sensor array", perspective: "world")

    # Distinct relation counts (widget 5, hub 6, dial 4, router 3, gauge 2, probe 2, relay 1, guide 1)
    # keep subgraph mode's structural ranking free of ties.
    { hub: %i[widget router dial gauge probe relay], widget: %i[router dial gauge probe], guide: %i[router],
      dial: %i[part18 part17] }.each do |from, targets|
      targets.each do |to|
        MemoryRelation.create!(from_entity: entities.fetch(from), to_entity: entities.fetch(to), relation_type: "depends_on")
      end
    end

    allow_any_instance_of(HybridSearchStrategy).to receive(:search).and_wrap_original do |original, *args, **options|
      original.call(*args, **options).tap { |results| @fused_scores = results.map(&:score) }
    end
    allow(VectorSearchStrategy).to receive(:new).and_return(vector)
    # A query with "zzqx" finds nothing in any channel (the temporal fallback case).
    allow(vector).to receive(:search) do |query, limit: 20, **|
      next [] if query.include?("zzqx")

      entity_vector_names.first(limit).map { |name| VectorSearchStrategy::SearchResult.new(entity: by_name(name), distance: 0.3) }
    end
    allow(vector).to receive(:search_observations) do |query, limit: 50, perspective: nil, **|
      next [] if query.include?("zzqx")

      observation_vector_names.fetch(perspective).first(limit).map { |name| by_name(name).id }
    end
  end

  describe "catalog mode" do
    it "lists entities by id, paged" do
      result = tool.call(page: 2, per_page: 5)

      expect(result.keys).to eq(%i[mode entities pagination])
      expect(result[:mode]).to eq("catalog")
      expect(result[:entities].pluck(:name)).to eq(recorded.fetch(:catalog_page2))
      expect(result[:pagination]).to eq(total_entities: 31, per_page: 5, current_page: 2, total_pages: 7)
    end
  end

  describe "summary mode" do
    { [ 1, 5 ] => :summary_p1_5, [ 2, 5 ] => :summary_p2_5, [ 1, 20 ] => :summary_p1_20, [ 2, 20 ] => :summary_p2_20 }.each do |(page, per_page), key|
      it "ranks page #{page} at per_page #{per_page}" do
        result = tool.call(query: "synth", page: page, per_page: per_page)

        expect(result.keys).to eq(%i[mode results pagination retrieval])
        expect(result[:results].first.keys).to eq(%i[entity_id name entity_type project_id description aliases
                                                     memory_observations_count created_at updated_at relevance_score matched_fields])
        expect(names(result[:results])).to eq(recorded.fetch(key))
        expect_no_ties
        expect(result[:pagination]).to eq(per_page: per_page, current_page: page)
        expect(result[:retrieval]).to eq(scope_entity_count: nil, scope_truncated: false, scope_max_entities: nil,
                                         result_count: result[:results].size, semantic: true)
      end
    end

    it "reports matched fields per channel" do
      result = tool.call(query: "synth", per_page: 8)

      expect(result[:results].to_h { |row| [ row[:name], row[:matched_fields] ] }).to eq(recorded.fetch(:matched_fields))
    end

    it "strips a temporal phrase from the query and weights by it" do
      result = tool.call(query: "synth in October 2026", per_page: 10)

      expect(names(result[:results])).to eq(recorded.fetch(:phrase))
      expect_no_ties
      expect(result[:retrieval][:temporal]).to eq(recorded.fetch(:phrase_diagnostic))
    end

    it "weights by occurred_after" do
      result = tool.call(query: "synth", occurred_after: "2026-09-01", per_page: 10)

      expect(names(result[:results])).to eq(recorded.fetch(:occurred_after))
      expect_no_ties
      expect(result[:retrieval][:temporal].keys).to eq(recorded.fetch(:temporal_keys))
    end

    it "weights by as_of" do
      result = tool.call(query: "synth", as_of: "2025-06-01", per_page: 10)

      expect(names(result[:results])).to eq(recorded.fetch(:as_of))
      expect_no_ties
    end

    it "lists a temporal-only query by in-window facts" do
      result = tool.call(query: "in October 2026")

      expect(names(result[:results])).to eq(recorded.fetch(:temporal_only))
      expect_no_ties
    end

    it "falls back to a temporal listing when the residual terms match nothing" do
      result = tool.call(query: "zzqx in October 2026")

      expect(names(result[:results])).to eq(recorded.fetch(:temporal_fallback))
      expect_no_ties
      expect(result[:retrieval][:temporal]).to include(fallback: "temporal_only")
    end

    %w[world experience].each do |perspective|
      it "filters observations by the #{perspective} perspective" do
        result = tool.call(query: "synth", perspective: perspective, per_page: 25)

        expect(names(result[:results])).to eq(recorded.fetch(:"perspective_#{perspective}"))
        expect_no_ties
      end
    end

    it "packs the page under max_tokens" do
      result = tool.call(query: "synth", per_page: 10, max_tokens: 600)

      expect(names(result[:results])).to eq(recorded.fetch(:max_tokens))
      expect(result[:retrieval].keys).to eq(%i[scope_entity_count scope_truncated scope_max_entities result_count semantic token_budget next_move])
      # estimated_tokens moves by a token or two with the ids' digit count, so it's checked by range.
      expect(result[:retrieval][:token_budget].except(:estimated_tokens))
        .to eq(max_tokens: 600, truncated: true, envelope_tokens: 179, items_before: 10, items_after: 5, dropped_on_page: 5)
      expect(result[:retrieval][:token_budget][:estimated_tokens]).to be_between(300, 600 - 179)
    end

    it "boosts the active context's project without filtering" do
      GraphMemContext.current_project_id = gadget.id

      result = tool.call(query: "synth", per_page: 10)

      expect(names(result[:results])).to eq(recorded.fetch(:context))
      expect_no_ties
      expect(result[:retrieval][:scope_entity_count]).to eq(recorded.fetch(:context_scope_count))
    end
  end

  describe "subgraph mode" do
    it "returns ranked entities with observations and relations" do
      result = tool.call(query: "sensor", include: %w[observations relations], per_page: 5)

      expect(result.keys).to eq(%i[mode entities pagination retrieval relations])
      expect(names(result[:entities])).to eq(recorded.fetch(:subgraph))
      expect(result[:pagination]).to eq(recorded.fetch(:subgraph_pagination))
      expect(result[:relations].size).to eq(recorded.fetch(:subgraph_relations))
    end

    %i[search_in_name search_in_type search_in_aliases search_in_observations].each do |flag|
      it "matches without #{flag}" do
        result = tool.call(query: "sensor", include: %w[observations], flag => false)

        expect(names(result[:entities])).to eq(recorded.fetch(:"subgraph_without_#{flag}"))
        expect(result[:pagination][:total_entities]).to eq(result[:entities].size)
      end
    end
  end

  describe "validation" do
    {
      { query: "" } => "Query term cannot be blank.",
      { include: %w[relations] } => "include, temporal bounds and max_tokens require a query.",
      { occurred_after: "2026-08-01" } => "include, temporal bounds and max_tokens require a query.",
      { query: "synth", include: %w[bogus] } => "include values must be observations and/or relations; received bogus.",
      { page: 0 } => "Page number must be 1 or greater.",
      { per_page: 101 } => "Per page count must be between 1 and 100.",
      { query: "synth", perspective: "opinion" } =>
        "perspective must be one of world, experience (world = external fact, experience = work-log entry).",
      { query: "synth", max_tokens: 0 } => "max_tokens must be an integer between 1 and 100000",
      { query: "synth", as_of: "2026-08-15", occurred_after: "2026-08-01" } =>
        "as_of cannot be combined with occurred_after/occurred_before",
      { query: "synth", occurred_after: "2026-09-01", occurred_before: "2026-08-01" } =>
        "occurred_after must be on or before occurred_before",
      { query: "synth", occurred_after: "someday" } => 'invalid temporal bound (expected ISO 8601): "someday"',
      { query: "synth", include: %w[observations], search_in_name: false, search_in_type: false,
        search_in_aliases: false, search_in_observations: false } =>
        "At least one search field (name, type, aliases, observations) must be enabled."
    }.each do |args, message|
      it "refuses #{args.inspect}" do
        expect { tool.call(**args) }.to raise_error(GraphMem::InvalidArgumentsError, message)
      end
    end
  end

  # UI-3 F4: project_id, entity_types and the search_in_* flags in both modes. Added after the
  # gate; the examples above are unchanged.
  describe "filters" do
    let(:alpha_names) { MemoryEntity.where(project_id: alpha.id).or(MemoryEntity.where(id: alpha.id)).pluck(:name) }
    let(:gadget_names) { MemoryEntity.where(project_id: gadget.id).or(MemoryEntity.where(id: gadget.id)).pluck(:name) }

    def search(**args) = GraphSearch.call(context_scope: nil, **args)

    # The vector stubs honour scope: as the real WHERE does.
    before do
      in_scope = ->(names, scope) { scope ? names.select { |name| scope.where(name: name).exists? } : names }
      allow(vector).to receive(:search) do |query, limit: 20, scope: nil, **|
        next [] if query.include?("zzqx")

        in_scope.call(entity_vector_names, scope).first(limit)
                .map { |name| VectorSearchStrategy::SearchResult.new(entity: by_name(name), distance: 0.3) }
      end
      allow(vector).to receive(:search_observations) do |query, limit: 50, perspective: nil, scope: nil, **|
        next [] if query.include?("zzqx")

        in_scope.call(observation_vector_names.fetch(perspective), scope).first(limit).map { |name| by_name(name).id }
      end
    end

    it "gives explicit default flags the same output as omitted ones, in both modes" do
      defaults = { search_in_name: true, search_in_type: true, search_in_aliases: true, search_in_observations: true,
                   entity_types: [], project_id: nil }

      expect(search(query: "synth", per_page: 25, **defaults)).to eq(search(query: "synth", per_page: 25))
      expect(search(query: "sensor", include: %w[observations], **defaults)).to eq(search(query: "sensor", include: %w[observations]))
    end

    it "keeps a project's root and members only, and pages through the filtered ranking" do
      all = search(query: "synth", project_id: alpha.id, per_page: 25)
      page2 = search(query: "synth", project_id: alpha.id, page: 2, per_page: 5)

      expect(names(all[:results])).to all(be_in(alpha_names))
      expect(names(all[:results])).to include("SynthWidget", "Synth Gauge", "Calibration Guide", "Synth Part 01", "Synth Part 09")
      expect(names(page2[:results])).to eq(names(all[:results])[5, 5])
      expect(all[:retrieval][:filters]).to eq(project_id: alpha.id, entity_types: [], search_in: %w[name type aliases observations])
    end

    it "keeps the listed types only, alone and combined with a project" do
      expect(names(search(query: "synth", entity_types: [ "service" ])[:results])).to eq([ "Synth Router" ])

      combined = search(query: "synth", project_id: alpha.id, entity_types: [ "Component" ], per_page: 25)
      expect(names(combined[:results])).to contain_exactly("SynthWidget", "Synth Gauge", "Synth Part 02", "Synth Part 04",
                                                           "Synth Part 06", "Synth Part 08")
    end

    it "filters subgraph mode's candidates and reports the filter" do
      result = search(query: "sensor", include: %w[observations], project_id: alpha.id)

      expect(names(result[:entities])).to eq([ "Sensor Hub", "SynthWidget", "Alpha Service", "Calibration Guide" ])
      expect(result[:pagination]).to include(total_entities: 4)
      expect(result[:retrieval][:filters]).to include(project_id: alpha.id)
    end

    it "combines with perspective and an occurred-time window" do
      experience = search(query: "synth", perspective: "experience", project_id: gadget.id, per_page: 25)
      windowed = search(query: "synth", occurred_after: "2026-09-01", project_id: gadget.id, per_page: 25)

      expect(names(experience[:results])).to all(be_in(gadget_names)).and include("SynthDial")
      expect(names(windowed[:results])).to all(be_in(gadget_names))
      expect(windowed[:retrieval]).to include(:temporal, :filters)
    end

    it "filters a temporal-only query and its fallback" do
      temporal_only = search(query: "in October 2026", project_id: alpha.id)
      fallback = search(query: "zzqx in October 2026", project_id: alpha.id)

      expect(names(temporal_only[:results])).to eq([ "SynthWidget", "Synth Gauge", "Synth Part 03" ])
      expect(names(fallback[:results])).to eq([ "SynthWidget", "Synth Gauge", "Synth Part 03" ])
      expect(fallback[:retrieval][:temporal]).to include(fallback: "temporal_only")
    end

    it "packs the filtered page under max_tokens" do
      full = search(query: "synth", project_id: alpha.id, per_page: 10)
      packed = search(query: "synth", project_id: alpha.id, per_page: 10, max_tokens: 600)

      expect(names(packed[:results])).to eq(names(full[:results]).first(packed[:results].size))
      expect(packed[:retrieval][:token_budget]).to include(truncated: true, items_before: 10)
    end

    it "runs only the observation channel when only observations are matched" do
      allow_any_instance_of(EntitySearchStrategy).to receive(:search).and_raise("text channel called")

      result = search(query: "synth", search_in_name: false, search_in_type: false, search_in_aliases: false, per_page: 25)

      expect(vector).not_to have_received(:search)
      expect(result[:results].pluck(:matched_fields)).to all(eq([ "observation_semantic" ]))
      expect(names(result[:results])).to contain_exactly("Relay Board", "Synth Gauge", "SynthDial", "Calibration Guide")
    end

    it "skips the observation channel when observations aren't matched" do
      result = search(query: "synth", search_in_type: false, search_in_aliases: false, search_in_observations: false, per_page: 25)

      expect(vector).not_to have_received(:search_observations)
      expect(result[:results].flat_map { |row| row[:matched_fields] }.uniq).to contain_exactly("name", "semantic")
      expect(result[:retrieval][:filters]).to include(search_in: [ "name" ])
    end

    it "refuses project_id or entity_types in catalog mode" do
      [ { project_id: alpha.id }, { entity_types: [ "Component" ] } ].each do |args|
        expect { search(query: nil, **args) }
          .to raise_error(GraphMem::InvalidArgumentsError, "project_id and entity_types require a query.")
      end
      expect(search(query: nil, entity_types: [])[:mode]).to eq("catalog")
    end

    it "reports retrieval.filters only when a filter is set" do
      expect(search(query: "synth")[:retrieval]).not_to have_key(:filters)
      expect(search(query: "sensor", include: %w[observations])[:retrieval]).not_to have_key(:filters)
      expect(search(query: "synth", entity_types: [ "Note" ])[:retrieval][:filters])
        .to eq(project_id: nil, entity_types: [ "Note" ], search_in: %w[name type aliases observations])
    end
  end

  # Recorded from SearchTool#call at 8ef3c04, before GraphSearch existed.
  let(:recorded) do
    {
      catalog_page2: [ "SynthDial", "Synth Ledger", "Calibration Guide", "Relay Board", "Sensor Hub" ],
      summary_p1_5: [ "Synth Router", "SynthWidget", "Synth Gauge", "Synth Part 02", "Synth Part 04" ],
      summary_p2_5: [ "Synth Part 18", "Synth Part 06", "Synth Part 08", "Synth Part 10", "Synth Part 12" ],
      summary_p1_20: [ "Synth Router", "SynthWidget", "Synth Gauge", "SynthDial", "Synth Part 02", "Synth Part 04", "Synth Part 18", "Synth Part 06", "Synth Part 08", "Synth Part 10", "Synth Part 12", "Synth Part 14", "Synth Part 16", "Synth Part 17", "Synth Ledger", "Synth Part 01", "Synth Part 03", "Synth Part 05", "Synth Part 07", "Synth Part 09" ],
      summary_p2_20: [ "Synth Part 11", "Synth Part 13", "Synth Part 15", "Calibration Guide", "Relay Board", "Alpha Service" ],
      matched_fields: { "Synth Router" => [ "name", "aliases", "semantic" ], "SynthWidget" => [ "name", "aliases", "semantic" ], "Synth Gauge" => [ "name", "observation_semantic" ], "Synth Part 02" => [ "name" ], "Synth Part 04" => [ "name" ], "Synth Part 18" => [ "name" ], "Synth Part 06" => [ "name" ], "Synth Part 08" => [ "name" ] },
      phrase: [ "SynthWidget", "Synth Gauge", "Synth Router", "SynthDial", "Synth Part 03", "Synth Part 02", "Synth Part 04", "Synth Part 18", "Synth Part 06", "Synth Part 08" ],
      phrase_diagnostic: { occurred_after: "2026-10-01T00:00:00Z", occurred_before: "2026-10-31T23:59:59Z", matched_phrase: "in october 2026" },
      occurred_after: [ "SynthWidget", "Synth Gauge", "Synth Router", "SynthDial", "Synth Part 03", "Synth Part 02", "Synth Part 04", "Synth Part 18", "Synth Part 06", "Synth Part 08" ],
      temporal_keys: [ :occurred_after ],
      as_of: [ "SynthWidget", "Synth Router", "Synth Gauge", "Synth Part 02", "Synth Part 04", "Synth Part 18", "Synth Part 06", "Synth Part 08", "Synth Part 10", "Synth Part 12" ],
      temporal_only: [ "SynthWidget", "SynthDial", "Synth Gauge", "Relay Board", "Synth Part 03" ],
      temporal_fallback: [ "SynthWidget", "SynthDial", "Synth Gauge", "Relay Board", "Synth Part 03" ],
      perspective_world: [ "Synth Router", "SynthWidget", "Synth Gauge", "Synth Part 02", "Synth Part 04", "Synth Part 18", "Synth Part 06", "Synth Part 08", "Synth Part 10", "Synth Part 12", "Synth Part 14", "Synth Part 16", "SynthDial", "Synth Part 17", "Synth Ledger", "Synth Part 01", "Synth Part 03", "Synth Part 05", "Synth Part 07", "Synth Part 09", "Synth Part 11", "Synth Part 13", "Synth Part 15", "Relay Board", "Calibration Guide" ],
      perspective_experience: [ "Synth Router", "SynthWidget", "SynthDial", "Synth Gauge", "Synth Part 02", "Synth Part 04", "Synth Part 18", "Synth Part 06", "Synth Part 08", "Synth Part 10", "Synth Part 12", "Synth Part 14", "Synth Part 16", "Synth Part 17", "Synth Ledger", "Synth Part 01", "Synth Part 03", "Synth Part 05", "Synth Part 07", "Synth Part 09", "Synth Part 11", "Synth Part 13", "Synth Part 15", "Calibration Guide", "Alpha Service" ],
      max_tokens: [ "Synth Router", "SynthWidget", "Synth Gauge", "Synth Part 02", "Synth Part 04" ],
      context: [ "Synth Router", "SynthWidget", "Synth Part 18", "Synth Part 10", "Synth Part 12", "Synth Part 14", "Synth Part 16", "SynthDial", "Synth Gauge", "Synth Part 11" ],
      context_scope_count: 14,
      subgraph: [ "Sensor Hub", "SynthWidget", "Synth Router", "Alpha Service", "Thermo Probe" ],
      subgraph_pagination: { total_entities: 9, per_page: 5, current_page: 1, total_pages: 2 },
      subgraph_relations: 5,
      subgraph_without_search_in_name: [ "SynthWidget", "Synth Router", "Alpha Service", "Thermo Probe", "Relay Board", "Calibration Guide", "Signal Box", "Bench Rig" ],
      subgraph_without_search_in_type: [ "Sensor Hub", "SynthWidget", "Synth Router", "Alpha Service", "Relay Board", "Calibration Guide", "Signal Box", "Bench Rig" ],
      subgraph_without_search_in_aliases: [ "Sensor Hub", "SynthWidget", "Synth Router", "Alpha Service", "Thermo Probe", "Relay Board", "Calibration Guide", "Bench Rig" ],
      subgraph_without_search_in_observations: [ "Sensor Hub", "SynthWidget", "Synth Router", "Alpha Service", "Thermo Probe", "Relay Board", "Calibration Guide", "Signal Box" ]
    }
  end
end
