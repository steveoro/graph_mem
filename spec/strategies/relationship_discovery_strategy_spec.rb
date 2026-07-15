# frozen_string_literal: true

require "rails_helper"

RSpec.describe RelationshipDiscoveryStrategy, type: :model do
  let(:strategy) { described_class.new }

  describe "#proposals_for_entity" do
    it "proposes relates_to for shared observation evidence" do
      left = MemoryEntity.create!(name: "SharedLeft", entity_type: "Task")
      right = MemoryEntity.create!(name: "SharedRight", entity_type: "Task")
      shared_content = "Shared dependency on BenchProject auth module"
      left_obs = MemoryObservation.create!(memory_entity: left, content: shared_content)
      right_obs = MemoryObservation.create!(memory_entity: right, content: shared_content)

      proposals = strategy.proposals_for_entity(left.id)

      expect(proposals.size).to eq(1)
      expect(proposals.first).to include(
        kind: "relationship_proposal",
        from_entity_id: left.id,
        to_entity_id: right.id,
        relation_type: "relates_to",
        confidence_band: "high",
        supporting_observation_ids: [ left_obs.id, right_obs.id ],
        explanation: be_present
      )
    end

    it "ignores obsolete observation evidence" do
      left = MemoryEntity.create!(name: "HistoricalLeft", entity_type: "Task")
      right = MemoryEntity.create!(name: "HistoricalRight", entity_type: "Task")
      shared_content = "Historical shared dependency on auth module"
      MemoryObservation.create!(memory_entity: left, content: shared_content).mark_obsolete!
      MemoryObservation.create!(memory_entity: right, content: shared_content)

      expect(strategy.proposals_for_entity(left.id)).to be_empty
    end

    it "proposes solves for issue and solution observation pairs" do
      issue = MemoryEntity.create!(name: "BenchProject_auth_issue", entity_type: "Issue")
      solution = MemoryEntity.create!(name: "BenchProject_auth_fix", entity_type: "PossibleSolution")
      issue_obs = MemoryObservation.create!(memory_entity: issue, content: "Blocks BenchProject login flow")
      solution_obs = MemoryObservation.create!(memory_entity: solution, content: "Fixes BenchProject login flow")

      proposals = strategy.proposals_for_entity(solution.id)

      expect(proposals.size).to eq(1)
      expect(proposals.first).to include(
        kind: "relationship_proposal",
        from_entity_id: solution.id,
        to_entity_id: issue.id,
        relation_type: "solves",
        confidence_band: "high",
        score: 14,
        supporting_observation_ids: [ solution_obs.id, issue_obs.id ]
      )
    end

    it "assigns medium confidence when issue-solution pairs share only two topic tokens" do
      issue = MemoryEntity.create!(name: "Alpha_login_issue", entity_type: "Issue")
      solution = MemoryEntity.create!(name: "Alpha_login_fix", entity_type: "PossibleSolution")
      issue_obs = MemoryObservation.create!(memory_entity: issue, content: "Blocks alpha login")
      solution_obs = MemoryObservation.create!(memory_entity: solution, content: "Fixes alpha login")

      proposals = strategy.proposals_for_entity(solution.id)

      expect(proposals.size).to eq(1)
      expect(proposals.first).to include(
        relation_type: "solves",
        confidence_band: "medium",
        score: 11,
        supporting_observation_ids: [ solution_obs.id, issue_obs.id ]
      )
    end

    it "skips proposals when the same-direction relation already exists" do
      left = MemoryEntity.create!(name: "ExistingLeft", entity_type: "Task")
      right = MemoryEntity.create!(name: "ExistingRight", entity_type: "Task")
      shared_content = "Shared dependency on BenchProject auth module"
      MemoryObservation.create!(memory_entity: left, content: shared_content)
      MemoryObservation.create!(memory_entity: right, content: shared_content)
      MemoryRelation.create!(from_entity: left, to_entity: right, relation_type: "relates_to")

      proposals = strategy.proposals_for_entity(left.id)

      expect(proposals).to be_empty
    end

    it "skips weak token overlap without shared observation phrases" do
      left = MemoryEntity.create!(name: "WeakLeft", entity_type: "Task")
      right = MemoryEntity.create!(name: "WeakRight", entity_type: "Task")
      MemoryObservation.create!(memory_entity: left, content: "alpha")
      MemoryObservation.create!(memory_entity: right, content: "beta")

      proposals = strategy.proposals_for_entity(left.id)

      expect(proposals).to be_empty
    end

    it "returns deterministic ordering and caps proposals per entity" do
      source = MemoryEntity.create!(name: "CapSource", entity_type: "Task")
      peers = 4.times.map do |index|
        peer = MemoryEntity.create!(name: "CapPeer#{index}", entity_type: "Task")
        shared = "Shared dependency on BenchProject auth module #{index}"
        MemoryObservation.create!(memory_entity: source, content: shared)
        MemoryObservation.create!(memory_entity: peer, content: shared)
        peer
      end

      proposals = strategy.proposals_for_entity(source.id)

      expect(proposals.size).to eq(RelationshipDiscoveryStrategy::MAX_PROPOSALS_PER_ENTITY)
      expect(proposals.map { |proposal| proposal[:to_entity_id] }).to eq(
        peers.first(RelationshipDiscoveryStrategy::MAX_PROPOSALS_PER_ENTITY).map(&:id)
      )
    end

    it "proposes depends_on when an observation names another entity with dependency language" do
      dependency = MemoryEntity.create!(name: "AuthModule", entity_type: "Task")
      dependent = MemoryEntity.create!(name: "LoginFeature", entity_type: "Task")
      observation = MemoryObservation.create!(
        memory_entity: dependent,
        content: "LoginFeature depends on AuthModule for session validation"
      )

      proposals = strategy.proposals_for_entity(dependent.id)

      expect(proposals).to include(
        hash_including(
          kind: "relationship_proposal",
          from_entity_id: dependent.id,
          to_entity_id: dependency.id,
          relation_type: "depends_on",
          supporting_observation_ids: [ observation.id ]
        )
      )
    end
  end
end
