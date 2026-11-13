# frozen_string_literal: true

require "rails_helper"

RSpec.describe RelationshipDiscoveryStrategy, type: :model do
  let(:strategy) { described_class.new }

  describe "#proposals_for_entity" do
    it "never proposes relates_to from identical observation content, however distinctive" do
      left = MemoryEntity.create!(name: "SharedLeft", entity_type: "Task")
      right = MemoryEntity.create!(name: "SharedRight", entity_type: "Task")
      shared_content = "The importer retries three times with exponential backoff."
      MemoryObservation.create!(memory_entity: left, content: shared_content)
      MemoryObservation.create!(memory_entity: right, content: shared_content)

      expect(strategy.proposals_for_entity(left.id)).to be_empty
      expect(strategy.proposals_for_entity(right.id)).to be_empty
    end

    it "yields no proposals for a boilerplate clique sharing one metadata line" do
      clique = 5.times.map { |index| MemoryEntity.create!(name: "StatusClique#{index}", entity_type: "Task") }
      clique.each { |member| MemoryObservation.create!(memory_entity: member, content: "Status: Completed") }

      clique.each { |member| expect(strategy.proposals_for_entity(member.id)).to be_empty }
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

    it "does not propose issue-solution links outside a supplied project scope" do
      issue = MemoryEntity.create!(name: "OutsideScopeIssue", entity_type: "Issue")
      solution = MemoryEntity.create!(name: "ScopedSolution", entity_type: "PossibleSolution")
      MemoryObservation.create!(memory_entity: issue, content: "Blocks scoped authentication flow")
      MemoryObservation.create!(memory_entity: solution, content: "Fixes scoped authentication flow")

      expect(strategy.proposals_for_entity(solution.id, scope_entity_ids: [ solution.id ])).to be_empty
    end

    it "does not propose solves when the pair shares only two topic terms" do
      issue = MemoryEntity.create!(name: "Alpha_login_issue", entity_type: "Issue")
      solution = MemoryEntity.create!(name: "Alpha_login_fix", entity_type: "PossibleSolution")
      MemoryObservation.create!(memory_entity: issue, content: "Blocks alpha login")
      MemoryObservation.create!(memory_entity: solution, content: "Fixes alpha login")

      expect(strategy.proposals_for_entity(solution.id)).to be_empty
    end

    it "proposes solves, in the high band, when the pair shares three topic terms" do
      issue = MemoryEntity.create!(name: "Beta_login_issue", entity_type: "Issue")
      solution = MemoryEntity.create!(name: "Beta_login_fix", entity_type: "PossibleSolution")
      MemoryObservation.create!(memory_entity: issue, content: "Blocks beta login flow")
      MemoryObservation.create!(memory_entity: solution, content: "Fixes beta login flow")

      proposals = strategy.proposals_for_entity(solution.id)

      expect(proposals.size).to eq(1)
      expect(proposals.first).to include(relation_type: "solves", confidence_band: "high", score: 14)
      expect(proposals.first[:evidence_terms].size).to be >= 3
    end

    it "skips proposals when the same-direction relation already exists" do
      issue = MemoryEntity.create!(name: "Gamma_login_issue", entity_type: "Issue")
      solution = MemoryEntity.create!(name: "Gamma_login_fix", entity_type: "PossibleSolution")
      MemoryObservation.create!(memory_entity: issue, content: "Blocks gamma login flow")
      MemoryObservation.create!(memory_entity: solution, content: "Fixes gamma login flow")
      MemoryRelation.create!(from_entity: solution, to_entity: issue, relation_type: "solves")

      expect(strategy.proposals_for_entity(solution.id)).to be_empty
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
      solution = MemoryEntity.create!(name: "CapSolution", entity_type: "PossibleSolution")
      MemoryObservation.create!(memory_entity: solution, content: "Fixes cap login flow")
      issues = 4.times.map do |index|
        issue = MemoryEntity.create!(name: "CapIssue#{index}", entity_type: "Issue")
        MemoryObservation.create!(memory_entity: issue, content: "Blocks cap login flow")
        issue
      end

      proposals = strategy.proposals_for_entity(solution.id)

      expect(proposals.size).to eq(RelationshipDiscoveryStrategy::MAX_PROPOSALS_PER_ENTITY)
      expect(proposals.map { |proposal| proposal[:to_entity_id] }).to eq(
        issues.first(RelationshipDiscoveryStrategy::MAX_PROPOSALS_PER_ENTITY).map(&:id)
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

  describe ".proposal_qualifies?" do
    let(:solves) do
      { relation_type: "solves", score: 14, evidence_terms: %w[alpha login flow],
        explanation: "Issue and solution observations share topic tokens: alpha, login, flow" }
    end

    it "rejects the removed identical-content relates_to rule" do
      payload = { relation_type: "relates_to", score: 10, evidence_terms: %w[shared dependency],
                  explanation: "Shared observation evidence on both entities" }

      expect(described_class.proposal_qualifies?(payload)).to be(false)
    end

    it "accepts a solves proposal with three terms in the high band" do
      expect(described_class.proposal_qualifies?(solves)).to be(true)
    end

    it "rejects a solves proposal with two terms or a score below the high band" do
      expect(described_class.proposal_qualifies?(solves.merge(evidence_terms: %w[alpha login], score: 11))).to be(false)
      expect(described_class.proposal_qualifies?(solves.merge(score: 11))).to be(false)
    end

    it "reads string-keyed payloads, as stored in review rows" do
      expect(described_class.proposal_qualifies?(solves.stringify_keys)).to be(true)
      expect(described_class.proposal_qualifies?(solves.stringify_keys.merge("evidence_terms" => %w[a b]))).to be(false)
    end

    it "accepts other relation types" do
      expect(described_class.proposal_qualifies?({ relation_type: "depends_on", score: 8 })).to be(true)
    end
  end
end
