# frozen_string_literal: true

require "rails_helper"

# C3a: `memory_observations.perspective` — world/experience split.
# Coverage: column validation, writes via graph_write/graph_edit tools,
# serialization, the search `perspective` hard filter, importer stamping,
# and the conservative migration backfill (known producers → world only).
RSpec.describe "Observation perspective (C3a)" do
  let(:entity) { MemoryEntity.create!(name: "Persp", entity_type: "Entity") }

  def obs(attrs = {})
    MemoryObservation.create!({ memory_entity: entity, content: "persp obs" }.merge(attrs))
  end

  it "validates perspective against the closed vocabulary" do
    expect(obs(perspective: "world")).to be_persisted
    expect(obs(perspective: "experience")).to be_persisted
    expect { obs(perspective: "worlds") }.to raise_error(ActiveRecord::RecordInvalid)
    expect(obs).to be_persisted # NULL stays valid
  end

  it "perspective is NOT an embedding field (no re-embed on change)" do
    expect(MemoryObservation::EMBEDDING_FIELDS).not_to include("perspective")
  end

  it "supersede! carries perspective onto the replacement" do
    original = obs(content: "typed fact", perspective: "world")
    original.supersede!(content: "typed fact v2", reason: "update")
    replacement = entity.memory_observations.order(:id).last
    expect(replacement.perspective).to eq("world")
    expect(replacement.status).to eq("active")
  end

  it "temporal channel respects the perspective filter" do
    obs(content: "planet fact", perspective: "world")
    exp_entity = MemoryEntity.create!(name: "PerspTemporal", entity_type: "Entity")
    MemoryObservation.create!(memory_entity: exp_entity, content: "planet log",
                              perspective: "experience")
    window = TemporalWindow.new(occurred_after: 2.days.ago.iso8601)
    world_ids = TemporalSearchStrategy.new.search(window, limit: 50, perspective: "world")
    expect(world_ids).to include(entity.id)
    expect(world_ids).not_to include(exp_entity.id)
  end

  it "is writable via graph_write create_observation and serialized" do
    result = GraphWriteService.execute_one(
      "create_observation",
      { entity_id: entity.id, text_content: "via graph_write", perspective: "experience" }
    )
    expect(result[:perspective]).to eq("experience")
    expect(MemoryObservation.find(result[:observation_id]).perspective).to eq("experience")
  end

  it "is writable via graph_edit update_observation" do
    target = obs
    result = GraphEditService.execute_one(
      "update_observation",
      { observation_id: target.id, perspective: "world" }
    )
    expect(result[:perspective]).to eq("world")
    expect(target.reload.perspective).to eq("world")
  end

  describe "search perspective hard filter" do
    before do
      obs(content: "planet fact", perspective: "world")
      obs(content: "planet log entry", perspective: "experience")
    end

    it "subgraph mode filters surfaced observations" do
      entities = SubgraphSearchService.call(query: "planet", include_observations: true,
                                            include_relations: false, perspective: "world")[:entities]
      contents = entities.flat_map { |e| e[:observations].map { |o| o[:content] } }
      expect(contents).to include("planet fact")
      expect(contents).not_to include("planet log entry")
    end

    it "entity payload includes perspective" do
      entities = SubgraphSearchService.call(query: "planet", include_observations: true,
                                            include_relations: false)[:entities]
      expect(entities.flat_map { |e| e[:observations].map { |o| o[:perspective] } })
        .to contain_exactly("world", "experience")
    end

    it "subgraph perspective filter excludes other-perspective obs from payloads" do
      entities = SubgraphSearchService.call(query: "planet", include_observations: true,
                                            include_relations: false,
                                            perspective: "world")[:entities]
      perspectives = entities.flat_map { |e| e[:observations].map { |o| o[:perspective] } }
      expect(perspectives).to eq([ "world" ])
    end

    it "subgraph perspective filter excludes an entity matching only via experience obs" do
      experience_only = MemoryEntity.create!(name: "ExperienceOnly", entity_type: "Entity")
      MemoryObservation.create!(memory_entity: experience_only, content: "unique planet experience",
                                perspective: "experience")

      entities = SubgraphSearchService.call(query: "planet", include_observations: true,
                                            include_relations: false,
                                            perspective: "world")[:entities]
      expect(entities.map { |e| e[:entity_id] }).not_to include(experience_only.id)
    end

    it "vector observation search applies the perspective filter" do
      strategy = VectorSearchStrategy.new(embedding_service: instance_double(EmbeddingService, embed: [ 0.0 ] * 768))
      allow(EmbeddingService).to receive(:vector_enabled?).and_return(true)
      relation = MemoryObservation.all
      allow(MemoryObservation).to receive(:active).and_return(relation)
      allow(relation).to receive(:with_embedding).and_return(relation)
      %i[select group order limit pluck].each { |m| allow(relation).to receive(m).and_return(relation) }
      allow(relation).to receive(:pluck).and_return([])
      expect(relation).to receive(:where).with(perspective: "world").and_return(relation)
      strategy.search_observations("q", perspective: "world")
    end

    it "summary mode threads perspective to retrieval" do
      expect(EntityRetrievalService).to receive(:search)
        .with("planet", hash_including(perspective: "experience"))
        .and_return(results: [], retrieval: { result_count: 0 })
      SearchTool.new.call(query: "planet", perspective: "experience")
    end

    it "rejects an invalid perspective value" do
      expect { SearchTool.new.call(query: "planet", perspective: "sideways") }
        .to raise_error(FastMcp::Tool::InvalidArgumentsError, /perspective must be one of/)
    end
  end

  it "import stamping: KNOWN_PRODUCERS → world, custom → NULL, explicit payload wins" do
    strategy = ImportExecutionStrategy.new
    entity2 = MemoryEntity.create!(name: "Persp2", entity_type: "Entity")
    node = { "observations" => [
      { "content" => "imported fact", "source" => "graphify" },
      { "content" => "custom source", "source" => "my_crawler" },
      { "content" => "explicit", "source" => "graphify", "perspective" => "experience" }
    ] }
    strategy.send(:import_observations, node, entity2)
    expect(entity2.memory_observations.order(:id).pluck(:perspective))
      .to eq([ "world", nil, "experience" ])
  end

  describe "migration backfill" do
    it "stamps world only for known code-structure producers" do
      load Rails.root.join("db/migrate/20261013110000_add_perspective_to_memory_observations.rb")
      migration = AddPerspectiveToMemoryObservations.new
      allow(migration).to receive(:add_column)
      allow(migration).to receive(:add_index)
      obs(content: "g fact", source: "graphify", perspective: nil)
      obs(content: "r fact", source: "rails_ast_extractor", perspective: nil)
      obs(content: "manual note", source: "user", perspective: nil)
      obs(content: "untyped", perspective: nil)
      migration.up
      perspectives = entity.memory_observations.order(:id).pluck(:source, :perspective)
      expect(perspectives).to eq([
        [ "graphify", "world" ], [ "rails_ast_extractor", "world" ], [ "user", nil ], [ nil, nil ]
      ])
    end
  end
end

RSpec.describe "caused_by relation type (C3b)" do
  it "canonicalizes backward-reading variants only" do
    %w[resulted_from triggered_by consequence_of].each do |variant|
      seed = RelationTypeMapping.find_or_initialize_by(variant: variant)
      seed.canonical_type = "caused_by"
      seed.save!
    end
    expect(RelationTypeMapping.canonicalize("resulted_from")).to eq("caused_by")
    expect(RelationTypeMapping.canonicalize("triggered_by")).to eq("caused_by")
    expect(RelationTypeMapping.canonicalize("consequence_of")).to eq("caused_by")
    # Forward verbs stay literal — nil = unmapped, callers keep the raw type.
    expect(RelationTypeMapping.canonicalize("led_to")).to be_nil
    expect(RelationTypeMapping.canonicalize("resulted_in")).to be_nil
  end
end
