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

    it "scores an exact alias token as an alias hit, not as a name substring" do
      node = MemoryEntity.new(name: "Coach", entity_type: "Task")
      match = strategy.match_to_projects(node).find { |m| m[:project].name == "CoachInABox" }

      expect(match[:score]).to eq(8)
    end
  end

  describe "suggestion gates" do
    after { GraphMemContext.clear! }

    it "does not suggest a project for a 2-letter substring token (if in Swiftshop)" do
      MemoryEntity.create!(name: "Swiftshop v2", entity_type: "Project")
      orphan = MemoryEntity.create!(name: "Make Sure The Scratch Folder Exists Before Writing", entity_type: "Task",
                                    description: "Create it if missing")

      matches = strategy.match_to_projects(orphan)

      expect(matches.map { |m| m[:project].name }).not_to include("Swiftshop v2")
    end

    it "does not suggest the context project from the +2 bonus alone" do
      GraphMemContext.current_project_id = project_coach.id
      orphan = MemoryEntity.create!(name: "Xyzzy Plugh Frobnicate", entity_type: "Task")

      expect(strategy.match_to_projects(orphan)).to be_empty
    end

    it "does not let the context bonus lift one name fragment over the floor" do
      project = MemoryEntity.create!(name: "Swiftshop v2", entity_type: "Project")
      GraphMemContext.current_project_id = project.id
      orphan = MemoryEntity.create!(name: "Shop rota export", entity_type: "Task")

      expect(strategy.match_to_projects(orphan).map { |m| m[:project].id }).not_to include(project.id)
    end

    it "still suggests a project matched on real tokens" do
      project = MemoryEntity.create!(name: "relay_admin2", entity_type: "Project")
      orphan = MemoryEntity.create!(name: "Patch Test Runner Script", entity_type: "Task",
                                    description: "relay admin2 script")

      match = strategy.match_to_projects(orphan).find { |m| m[:project].id == project.id }

      expect(match).to be_present
      expect(match[:score]).to be >= described_class::MIN_SUGGESTION_SCORE
      expect(match[:matched_tokens]).to include("relay", "admin2")
    end
  end

  describe ".suggestion_qualifies?" do
    it "is true when the project is still a live suggestion" do
      expect(described_class.suggestion_qualifies?(orphan_task, project_admin_hub)).to be(true)
    end

    it "is false when the project no longer matches" do
      expect(described_class.suggestion_qualifies?(orphan_issue, project_admin_hub)).to be(false)
    end
  end
end
