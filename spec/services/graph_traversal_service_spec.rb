# frozen_string_literal: true

require "rails_helper"

RSpec.describe GraphTraversalService do
  subject(:service) { described_class.new }

  let!(:a) { MemoryEntity.create!(name: "A", entity_type: "Project") }
  let!(:b) { MemoryEntity.create!(name: "B", entity_type: "Task") }
  let!(:c) { MemoryEntity.create!(name: "C", entity_type: "Task") }
  let!(:d) { MemoryEntity.create!(name: "D", entity_type: "Task") }
  let!(:e) { MemoryEntity.create!(name: "E", entity_type: "Task") }
  let!(:f) { MemoryEntity.create!(name: "F (isolated)", entity_type: "Task") }

  # A -> B -> C -> D -> B (cycle), plus A -> E
  let!(:r_ab) { MemoryRelation.create!(from_entity: a, to_entity: b, relation_type: "part_of") }
  let!(:r_bc) { MemoryRelation.create!(from_entity: b, to_entity: c, relation_type: "depends_on") }
  let!(:r_cd) { MemoryRelation.create!(from_entity: c, to_entity: d, relation_type: "depends_on") }
  let!(:r_db) { MemoryRelation.create!(from_entity: d, to_entity: b, relation_type: "part_of") }
  let!(:r_ae) { MemoryRelation.create!(from_entity: a, to_entity: e, relation_type: "relates_to") }

  describe "#expand" do
    it "returns nil when the start entity does not exist" do
      expect(service.expand(start_entity_id: 999_999)).to be_nil
    end

    it "includes the start entity and its immediate neighbors in deterministic order" do
      result = service.expand(start_entity_id: a.id, max_depth: 1, direction: "outgoing")

      expect(result.entity_ids).to eq([ a.id, b.id, e.id ])
      expect(result.relation_ids).to eq([ r_ab.id, r_ae.id ].sort)
      expect(result.visited_depth).to eq(1)
      expect(result.truncated).to be(false)
    end

    it "expands multiple hops and handles cycles safely" do
      result = service.expand(start_entity_id: a.id, max_depth: 4, direction: "outgoing")

      expect(result.entity_ids).to contain_exactly(a.id, b.id, c.id, d.id, e.id)
      # r_db closes the cycle back to an already-visited node and is still recorded
      expect(result.relation_ids).to include(r_db.id)
    end

    it "supports incoming traversal" do
      result = service.expand(start_entity_id: c.id, max_depth: 1, direction: "incoming")

      expect(result.entity_ids).to contain_exactly(c.id, b.id)
      expect(result.relation_ids).to eq([ r_bc.id ])
    end

    it "supports bidirectional traversal" do
      result = service.expand(start_entity_id: c.id, max_depth: 1, direction: "both")

      expect(result.entity_ids).to contain_exactly(c.id, b.id, d.id)
    end

    it "filters by canonical relation type" do
      RelationTypeMapping.create!(canonical_type: "depends_on", variant: "requires")

      result = service.expand(start_entity_id: b.id, max_depth: 2, direction: "outgoing", relation_types: [ "REQUIRES" ])

      expect(result.entity_ids).to contain_exactly(b.id, c.id, d.id)
      expect(result.relation_ids).to contain_exactly(r_bc.id, r_cd.id)
    end

    it "marks the result truncated when the entity cap is hit" do
      result = service.expand(start_entity_id: a.id, max_depth: 5, direction: "both", max_entities: 2)

      expect(result.entity_ids.size).to eq(2)
      expect(result.truncated).to be(true)
    end

    it "clamps max_depth to the hard maximum" do
      result = service.expand(start_entity_id: a.id, max_depth: 99)
      expect(result.max_depth).to eq(described_class::MAX_DEPTH)
    end

    it "returns only the start entity for a disconnected node" do
      result = service.expand(start_entity_id: f.id, max_depth: 3)

      expect(result.entity_ids).to eq([ f.id ])
      expect(result.relation_ids).to eq([])
      expect(result.visited_depth).to eq(0)
    end
  end

  describe "#shortest_path" do
    it "returns :missing_from when the source is absent" do
      expect(service.shortest_path(from_entity_id: 999_999, to_entity_id: a.id)).to eq(:missing_from)
    end

    it "returns :missing_to when the target is absent" do
      expect(service.shortest_path(from_entity_id: a.id, to_entity_id: 999_999)).to eq(:missing_to)
    end

    it "returns a zero-hop path when source equals target" do
      result = service.shortest_path(from_entity_id: a.id, to_entity_id: a.id)

      expect(result.found).to be(true)
      expect(result.hop_count).to eq(0)
      expect(result.entity_ids).to eq([ a.id ])
      expect(result.relation_ids).to eq([])
    end

    it "reconstructs the ordered path between two entities" do
      result = service.shortest_path(from_entity_id: a.id, to_entity_id: c.id, max_depth: 3, direction: "outgoing")

      expect(result.found).to be(true)
      expect(result.hop_count).to eq(2)
      expect(result.entity_ids).to eq([ a.id, b.id, c.id ])
      expect(result.relation_ids).to eq([ r_ab.id, r_bc.id ])
    end

    it "uses deterministic relation ordering for equal-length paths" do
      r_ec = MemoryRelation.create!(from_entity: e, to_entity: c, relation_type: "depends_on")

      result = service.shortest_path(from_entity_id: a.id, to_entity_id: c.id, max_depth: 2, direction: "outgoing")

      expect(result.relation_ids).to eq([ r_ab.id, r_bc.id ])
      expect(result.relation_ids).not_to include(r_ec.id)
    end

    it "supports incoming shortest paths" do
      result = service.shortest_path(from_entity_id: c.id, to_entity_id: a.id, max_depth: 2, direction: "incoming")

      expect(result.found).to be(true)
      expect(result.entity_ids).to eq([ c.id, b.id, a.id ])
      expect(result.relation_ids).to eq([ r_bc.id, r_ab.id ])
    end

    it "returns found: false when the target is beyond max_depth" do
      result = service.shortest_path(from_entity_id: a.id, to_entity_id: d.id, max_depth: 2, direction: "outgoing")

      expect(result.found).to be(false)
      expect(result.hop_count).to be_nil
      expect(result.entity_ids).to eq([])
    end

    it "finds a deeper path when max_depth allows" do
      result = service.shortest_path(from_entity_id: a.id, to_entity_id: d.id, max_depth: 3, direction: "outgoing")

      expect(result.found).to be(true)
      expect(result.hop_count).to eq(3)
      expect(result.entity_ids).to eq([ a.id, b.id, c.id, d.id ])
    end

    it "returns found: false for disconnected nodes" do
      result = service.shortest_path(from_entity_id: a.id, to_entity_id: f.id, max_depth: 5)
      expect(result.found).to be(false)
    end

    it "respects relation-type filters" do
      result = service.shortest_path(
        from_entity_id: a.id, to_entity_id: c.id, max_depth: 5, direction: "outgoing", relation_types: [ "depends_on" ]
      )
      # A -> B is part_of, so the depends_on-only path never leaves A
      expect(result.found).to be(false)
    end
  end
end
