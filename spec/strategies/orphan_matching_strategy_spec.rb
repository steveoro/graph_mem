# frozen_string_literal: true

require "rails_helper"

RSpec.describe OrphanMatchingStrategy, type: :model do
  let(:strategy) { described_class.new }

  # Setup test data
  let!(:project_admin_hub) do
    MemoryEntity.create!(
      name: "AdminHub",
      entity_type: "Project",
      aliases: "admin_hub,Admin Hub"
    )
  end

  let!(:project_coach) do
    MemoryEntity.create!(
      name: "CoachInABox",
      entity_type: "Project",
      aliases: "coach,coaching"
    )
  end

  let!(:orphan_task) do
    MemoryEntity.create!(
      name: "Admin Hub Journey Session CRUD Implementation",
      entity_type: "Task",
      aliases: ""
    )
  end

  let!(:orphan_issue) do
    MemoryEntity.create!(
      name: "Random Unrelated Issue",
      entity_type: "Issue",
      aliases: ""
    )
  end

  let!(:child_task) do
    entity = MemoryEntity.create!(
      name: "Child Task",
      entity_type: "Task",
      aliases: ""
    )

    # Make it a child of project_admin_hub
    MemoryRelation.create!(
      from_entity: entity,
      to_entity: project_admin_hub,
      relation_type: "part_of"
    )

    entity
  end

  describe "#orphan_nodes" do
    it "returns entities with no incoming part_of/depends_on relations" do
      orphans = strategy.orphan_nodes

      orphan_names = orphans.map(&:name)

      # Should include orphan_task and orphan_issue
      expect(orphan_names).to include("Admin Hub Journey Session CRUD Implementation")
      expect(orphan_names).to include("Random Unrelated Issue")
    end

    it "excludes Project entities" do
      orphans = strategy.orphan_nodes

      entity_types = orphans.map(&:entity_type)
      expect(entity_types).not_to include("Project")
    end

    it "excludes entities that are children of other entities" do
      orphans = strategy.orphan_nodes

      orphan_names = orphans.map(&:name)
      expect(orphan_names).not_to include("Child Task")
    end
  end

  describe "#match_to_projects" do
    it "matches orphan tokens to project names" do
      matches = strategy.match_to_projects(orphan_task)

      expect(matches).not_to be_empty
      expect(matches.first[:project].name).to eq("AdminHub")
    end

    it "returns matches sorted by score descending" do
      matches = strategy.match_to_projects(orphan_task)

      scores = matches.map { |m| m[:score] }
      expect(scores).to eq(scores.sort.reverse)
    end

    it "includes matched tokens in result" do
      matches = strategy.match_to_projects(orphan_task)

      best_match = matches.first
      expect(best_match[:matched_tokens]).to include("admin")
    end

    it "returns empty array for node with no matching tokens" do
      unrelated = MemoryEntity.new(
        name: "XyzQwerty123",
        entity_type: "Task"
      )

      matches = strategy.match_to_projects(unrelated)
      expect(matches).to be_empty
    end
  end

  describe "#orphans_with_matches" do
    it "returns array of orphan data with suggested parents" do
      result = strategy.orphans_with_matches

      expect(result).to be_an(Array)
      expect(result.first).to include(:id, :name, :entity_type, :suggested_parents)
    end

    it "includes match score and tokens for suggested parents" do
      result = strategy.orphans_with_matches

      orphan_with_matches = result.find { |o| o[:name] == "Admin Hub Journey Session CRUD Implementation" }

      expect(orphan_with_matches[:suggested_parents]).not_to be_empty
      expect(orphan_with_matches[:suggested_parents].first).to include(:id, :name, :score, :matched_tokens)
    end

    it "excludes Projects from orphan list" do
      result = strategy.orphans_with_matches

      entity_types = result.map { |o| o[:entity_type] }
      expect(entity_types).not_to include("Project")
    end
  end

  describe "tokenization" do
    it "splits names on spaces and common separators" do
      # Test via match_to_projects which uses tokenization internally
      node = MemoryEntity.new(name: "Admin_Hub-Journey.Session", entity_type: "Task")
      matches = strategy.match_to_projects(node)

      # Should match AdminHub due to "admin" and "hub" tokens
      expect(matches.first[:project].name).to eq("AdminHub")
    end

    it "ignores very short tokens" do
      node = MemoryEntity.new(name: "A B C Coach", entity_type: "Task")
      matches = strategy.match_to_projects(node)

      # Should match CoachInABox due to "coach" token, ignoring single-letter tokens
      matching_project = matches.find { |m| m[:project].name == "CoachInABox" }
      expect(matching_project).to be_present
    end
  end
end
