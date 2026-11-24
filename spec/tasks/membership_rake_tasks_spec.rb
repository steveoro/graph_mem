# frozen_string_literal: true

require "rails_helper"
require "rake"

# Item 6 of the part_of membership plan: the hand-run tasks that write part_of edges keep
# memory_entities.project_id in step with the part_of tree.
RSpec.describe "rake tasks writing part_of edges", type: :task do
  # Every task the two files define that a spec here runs, plus project_report (loaded again too).
  def task_names = %w[data:migrate_json data:append_json data:merge_entity data:project_report tools:create_relation]

  # Each task's action exactly once (other specs run Rails.application.load_tasks again and again).
  before do
    Rake::Task.define_task(:environment) unless Rake::Task.task_defined?("environment")
    task_names.each { |name| Rake::Task[name].clear if Rake::Task.task_defined?(name) }
    load Rails.root.join("lib/tasks/memory_data.rake")
    load Rails.root.join("lib/tasks/memory_graph_utilities.rake")
    allow(EmbeddingsMaintenanceEnqueuer).to receive(:enqueue!).and_call_original
  end

  after do
    task_names.each { |name| Rake::Task[name].reenable }
    @files&.each(&:unlink)
  end

  def json_lines_file(*lines)
    file = Tempfile.new([ "memory_data", ".json" ])
    lines.each { |line| file.puts(line.to_json) }
    file.close
    (@files ||= []) << file
    file.path
  end

  def entity_line(name, type) = { type: "entity", name: name, entityType: type }
  def relation_line(from, to, type = "part_of") = { type: "relation", from: from, to: to, relationType: type }

  def invoke(name, *args)
    depth = nil
    expect { depth = open_transactions_at_get_lock { Rake::Task[name].invoke(*args) } }.to output.to_stdout
    depth
  end

  describe "data:migrate_json" do
    it "stamps the part_of tree it loads, under the lock taken before any transaction" do
      path = json_lines_file(entity_line("Alpha Project", "Project"), entity_line("SynthWidget", "Component"),
                             entity_line("SynthGear", "Component"),
                             relation_line("SynthWidget", "Alpha Project"), relation_line("SynthGear", "SynthWidget"))

      expect(invoke("data:migrate_json", path)).to eq(0)

      project = MemoryEntity.find_by!(name: "Alpha Project")
      expect(MemoryEntity.where(name: %w[SynthWidget SynthGear]).pluck(:project_id)).to eq([ project.id, project.id ])
      expect(EmbeddingsMaintenanceEnqueuer).to have_received(:enqueue!).with("backfill")
      expect(membership_lock_free?).to be(true)
    end
  end

  describe "data:append_json" do
    let!(:project) { MemoryEntity.create!(name: "Alpha Project", entity_type: "Project") }

    it "stamps an appended child of an existing project" do
      path = json_lines_file(entity_line("SynthWidget", "Component"), relation_line("SynthWidget", "Alpha Project"))

      expect(invoke("data:append_json", path)).to eq(0)

      expect(MemoryEntity.find_by!(name: "SynthWidget").project_id).to eq(project.id)
    end

    # Drift is the point: the backfill refuses the stamp, so the appended edge has no stamp yet.
    it "aborts with the backfill's hint when the project already holds the name", membership_drift: :allowed do
      fs_member!(project, "SynthWidget", "Component")
      path = json_lines_file(entity_line("SynthWidget", "Class"), relation_line("SynthWidget", "Alpha Project"))

      expect {
        expect { Rake::Task["data:append_json"].invoke(path) }.to raise_error(SystemExit).and output.to_stdout
      }.to output(/project_id backfill aborted and rolled back: .*SynthWidget/m).to_stderr

      expect(MemoryEntity.find_by!(name: "SynthWidget", entity_type: "Class").project_id).to be_nil
    end
  end

  describe "data:merge_entity" do
    let(:alpha) { MemoryEntity.create!(name: "Alpha Project", entity_type: "Project") }
    let(:beta) { MemoryEntity.create!(name: "Beta Project", entity_type: "Project") }

    it "merges through merge_into: the target keeps its parent and takes the children, in one undoable change set" do
      target = fs_member!(alpha, "SynthWidget", "Component")
      source = fs_member!(beta, "SynthWidgetCopy", "Component")
      child = fs_member!(source, "SynthGear", "Component")

      expect(invoke("data:merge_entity", source.id.to_s, target.id.to_s)).to eq(0)

      expect(MemoryEntity.exists?(source.id)).to be(false)
      expect(MemoryRelation.where(from_entity: target, relation_type: "part_of").pluck(:to_entity_id)).to eq([ alpha.id ])
      expect(MemoryRelation.where(from_entity: child, relation_type: "part_of").pluck(:to_entity_id)).to eq([ target.id ])
      expect(child.reload.project_id).to eq(alpha.id)
      expect(ChangeSet.where(kind: "merge", actor: "rake:merge_entity").sole).to be_undoable
    end

    it "re-embeds the survivor before it ends, after the membership lock is released", :with_test_embeddings do
      target = fs_member!(alpha, "SynthWidget", "Component")
      source = fs_member!(beta, "SynthWidgetCopy", "Component")
      calls = record_embedding_calls!

      invoke("data:merge_entity", source.id.to_s, target.id.to_s)

      expect(calls.sole).to include(text: "Component: SynthWidget. Aliases: SynthWidgetCopy", held: false, lock_free: true)
      expect(target.reload.embedded_at).to be_present
    end

    it "refuses entities of different types and merges nothing" do
      target = fs_member!(alpha, "SynthWidget", "Component")
      source = fs_member!(beta, "SynthWidgetCopy", "Class")

      expect {
        expect { Rake::Task["data:merge_entity"].invoke(source.id.to_s, target.id.to_s) }.to raise_error(SystemExit)
      }.to output(/Cannot merge entities of different types.*Nothing was merged/m).to_stdout

      expect(MemoryEntity.exists?(source.id)).to be(true)
      expect(ChangeSet.count).to eq(0)
    end
  end

  describe "tools:create_relation" do
    let!(:project) { MemoryEntity.create!(name: "Alpha Project", entity_type: "Project") }

    it "creates a part_of through graph_write: the child joins the project" do
      widget = MemoryEntity.create!(name: "SynthWidget", entity_type: "Component")

      expect(invoke("tools:create_relation", widget.id.to_s, project.id.to_s, "part_of")).to eq(0)

      expect(MemoryRelation.where(from_entity: widget, to_entity: project, relation_type: "part_of")).to exist
      expect(widget.reload.project_id).to eq(project.id)
    end

    it "refuses a second parent and writes nothing" do
      widget = fs_member!(project, "SynthWidget", "Component")
      other = fs_member!(project, "SynthGear", "Component")

      expect {
        Rake::Task["tools:create_relation"].invoke(widget.id.to_s, other.id.to_s, "part_of")
      }.to output(/Error creating relation: /).to_stdout

      expect(MemoryRelation.where(from_entity: widget, relation_type: "part_of").pluck(:to_entity_id)).to eq([ project.id ])
    end
  end
end
