# frozen_string_literal: true

require "rails_helper"
require "tmpdir"
require "json"

# Project-scoped entity names (round-6 spec, use-cases 2/4/6/7/8/10):
# name uniqueness is (project_scope, name), cross-repo references resolve
# own → single-declarer → global stub, and MCP writes land in context.
RSpec.describe "project-scoped entity names" do
  # Self-created data only — mirrors rails_ast_import_spec's purge (runner
  # debug scripts and fixture rows can leave committed leftovers behind).
  PURGED_NAMES = %w[RepoA RepoB RepoC StableRepo ProjA ProjB CtxProj ScopeProj
                    BackProj ReA ReB Notifiable Notifiable#notify notifiable.rb
                    post.rb account.rb Account Account#a Account#b swimmer.rb
                    Swimmer team.rb Team Thing OnlyB SharedGlobal CtxEntity
                    NewRoot GlobalOne BackChild BackGrand BackOrphan ReChild].freeze

  before { purge_fixture_names }
  after { purge_fixture_names }

  def purge_fixture_names
    # Members first: unclaiming before their destroy would collide a
    # member's name with an existing global (UNIQUE project_scope,name).
    %i[member project].each do |pass|
      MemoryEntity.where(name: PURGED_NAMES).find_each do |e|
        next if (pass == :member) == (e.entity_type == "Project")

        MemoryRelation.where(from_entity_id: e.id).or(
          MemoryRelation.where(to_entity_id: e.id)
        ).delete_all
        MemoryEntity.where(project_id: e.id).update_all(project_id: nil) if pass == :project
        e.destroy!
      end
    end
  end

  def import_payload(dir, project:)
    payload = RailsAstExtractor.extract(dir, project_name: project)
    result = GraphifyImporter.new(JSON.generate(payload), project_name: project).translate
    match = ImportMatchingStrategy.new.match(result.import_data)
    decisions = GraphifyImporter.headless_decisions(match[:match_results])
    ImportExecutionStrategy.new.execute(result.import_data, decisions)
  end

  def write_models(dir, files)
    FileUtils.mkdir_p(File.join(dir, "app/models"))
    files.each { |name, body| File.write(File.join(dir, "app/models/#{name}"), body) }
  end

  describe "use-case 2: same basename in two projects" do
    it "two account.rb files coexist as project-scoped entities" do
      Dir.mktmpdir do |dir_a|
        write_models(dir_a, "account.rb" => "class Account\n  def a; end\nend\n")
        expect(import_payload(dir_a, project: "RepoA").success).to be true
      end
      Dir.mktmpdir do |dir_b|
        write_models(dir_b, "account.rb" => "class Account\n  def b; end\nend\n")
        expect(import_payload(dir_b, project: "RepoB").success).to be true
      end

      files = MemoryEntity.where(name: "account.rb", entity_type: "File")
      classes = MemoryEntity.where(name: "Account", entity_type: "Class")
      expect(files.count).to eq(2)
      expect(classes.count).to eq(2)
      expect(files.map(&:project_id).uniq.size).to eq(2)
      expect(MemoryEntity.find_by(name: "Account#a")).to be_present
      expect(MemoryEntity.find_by(name: "Account#b")).to be_present
    end
  end

  describe "use-case 4: multi-declarer stub stays global" do
    it "keeps the stub and queues re-point proposals on the second declaration" do
      # RepoB references first → global stub.
      Dir.mktmpdir do |dir_b|
        write_models(dir_b, "post.rb" => "class Post\n  include Notifiable\nend\n")
        expect(import_payload(dir_b, project: "RepoB").success).to be true
      end
      stub = MemoryEntity.find_by!(name: "Notifiable")
      expect(stub.project_id).to be_nil

      # RepoA declares → single declarer at this point: claim moves the
      # stub into RepoA's project.
      Dir.mktmpdir do |dir_a|
        write_models(dir_a, "notifiable.rb" => "module Notifiable\n  def notify; end\nend\n")
        expect(import_payload(dir_a, project: "RepoA").success).to be true
      end
      expect(stub.reload.project_id).to eq(MemoryEntity.find_by(name: "RepoA").id)

      # RepoC now ALSO declares Notifiable: a project-scoped copy is
      # created (the stub stays with its claimant), and each cross-project
      # edge pointing at the claimed entity queues a re-point proposal.
      Dir.mktmpdir do |dir_c|
        write_models(dir_c, "notifiable.rb" => "module Notifiable\n  def notify2; end\nend\n")
        expect(import_payload(dir_c, project: "RepoC").success).to be true
      end

      declared = MemoryEntity.where(name: "Notifiable", entity_type: "Module").order(:id)
      expect(declared.count).to eq(2)
      expect(declared.map(&:project_id).compact.size).to eq(2)

      repoint = MaintenanceReportRow.where(kind: "relationship_proposal")
                                    .where("payload LIKE ?", "%re-point%")
      expect(repoint.count).to be >= 1
      expect(repoint.flat_map { |r| Array(r.payload["candidates"]) }.uniq.size).to eq(2)
    end
  end

  describe "use-case 6: scoped name resolution + MCP writes" do
    it "prefers the context project, falls back to global, raises on ambiguity" do
      project_a = MemoryEntity.create!(name: "ProjA", entity_type: "Project")
      project_b = MemoryEntity.create!(name: "ProjB", entity_type: "Project")
      in_a = MemoryEntity.create!(name: "Thing", entity_type: "Component", project_id: project_a.id)
      in_b = MemoryEntity.create!(name: "Thing", entity_type: "Component", project_id: project_b.id)
      global = MemoryEntity.create!(name: "SharedGlobal", entity_type: "Component")

      expect(ImportEntityResolver.find_by_name("Thing", project_id: project_a.id)).to eq(in_a)
      expect(ImportEntityResolver.find_by_name("SharedGlobal", project_id: project_a.id)).to eq(global)
      # Same name declared by two projects, no context → ambiguous, never guessed.
      expect { ImportEntityResolver.find_by_name("Thing") }
        .to raise_error(McpGraphMemErrors::AmbiguousReference)
      # A name only one project declares resolves through it.
      MemoryEntity.create!(name: "OnlyB", entity_type: "Component", project_id: project_b.id)
      expect(ImportEntityResolver.find_by_name("OnlyB", project_id: project_a.id).project_id).to eq(project_b.id)
    end

    it "graph_write creates entities inside the context project" do
      project = MemoryEntity.create!(name: "CtxProj", entity_type: "Project")
      payload = GraphWriteService.execute_one("create_entity",
                                            { "name" => "CtxEntity", "entity_type" => "Component" },
                                            project_id: project.id)
      expect(payload[:name]).to eq("CtxEntity")
      expect(MemoryEntity.find_by!(name: "CtxEntity").project_id).to eq(project.id)
      # …while a Project-typed create always lands in the global scope.
      GraphWriteService.execute_one("create_entity",
                                    { "name" => "NewRoot", "entity_type" => "Project" },
                                    project_id: project.id)
      expect(MemoryEntity.find_by!(name: "NewRoot").project_id).to be_nil
    end
  end

  describe "use-case 7: uniqueness" do
    it "rejects a duplicate global name at validation and at the unique index" do
      MemoryEntity.create!(name: "GlobalOne", entity_type: "Component")
      expect(MemoryEntity.new(name: "GlobalOne", entity_type: "Component")).not_to be_valid
      expect do
        MemoryEntity.insert!({ name: "GlobalOne", entity_type: "Component",
                               memory_observations_count: 0,
                               created_at: Time.current, updated_at: Time.current })
      end.to raise_error(ActiveRecord::RecordNotUnique)
      # …but the same name in a project scope is legal.
      project = MemoryEntity.create!(name: "ScopeProj", entity_type: "Project")
      expect(MemoryEntity.create!(name: "GlobalOne", entity_type: "Component",
                                  project_id: project.id)).to be_persisted
    end
  end

  describe "use-case 8: same repo twice" do
    it "produces identical entity/relation/observation counts" do
      Dir.mktmpdir do |dir|
        write_models(dir,
                     "swimmer.rb" => "class Swimmer < ApplicationRecord\n  belongs_to :team\nend\n",
                     "team.rb" => "class Team < ApplicationRecord\n  has_many :swimmers\nend\n")
        first = import_payload(dir, project: "StableRepo")
        counts = [ MemoryEntity.count, MemoryRelation.count, MemoryObservation.count ]
        second = import_payload(dir, project: "StableRepo")
        expect(second.success).to be true
        expect(second.entities_created).to eq(0)
        expect([ MemoryEntity.count, MemoryRelation.count, MemoryObservation.count ]).to eq(counts)
        # Content check: no duplicate provenance or dangling stub edges.
        expect(MemoryEntity.where(name: "StableRepo").count).to eq(1)
        expect(first.success).to be true
      end
    end
  end

  describe "use-case 10: backfill" do
    it "stamps members per tree, leaves unrooted NULL, and is idempotent" do
      project = MemoryEntity.create!(name: "BackProj", entity_type: "Project")
      child = MemoryEntity.create!(name: "BackChild", entity_type: "Task")
      grandchild = MemoryEntity.create!(name: "BackGrand", entity_type: "Task")
      MemoryRelation.create!(from_entity: child, to_entity: project, relation_type: "part_of")
      MemoryRelation.create!(from_entity: grandchild, to_entity: child, relation_type: "part_of")
      unrooted = MemoryEntity.create!(name: "BackOrphan", entity_type: "Task")

      report = ProjectIdBackfill.new(out: ->(_l) { }).run
      expect(report.changed).to be >= 2
      expect(child.reload.project_id).to eq(project.id)
      expect(grandchild.reload.project_id).to eq(project.id)
      expect(unrooted.reload.project_id).to be_nil
      expect(report.per_project[project.id]).to eq(2)

      second = ProjectIdBackfill.new(out: ->(_l) { }).run
      expect(second.changed).to eq(0)

      dry = ProjectIdBackfill.new(out: ->(_l) { }).run(dry_run: true)
      expect(dry.changed).to eq(0)
    end

    it "moves a member when its tree is re-parented under another project" do
      proj_a = MemoryEntity.create!(name: "ReA", entity_type: "Project")
      proj_b = MemoryEntity.create!(name: "ReB", entity_type: "Project")
      child = MemoryEntity.create!(name: "ReChild", entity_type: "Task", project_id: proj_a.id)
      MemoryRelation.create!(from_entity: child, to_entity: proj_b, relation_type: "part_of")

      ProjectIdBackfill.new(out: ->(_l) { }).run
      expect(child.reload.project_id).to eq(proj_b.id)
    end
  end
end
