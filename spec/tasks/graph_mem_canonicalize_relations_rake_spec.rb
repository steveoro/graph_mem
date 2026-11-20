# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "graph_mem:canonicalize_relations", type: :task do
  let(:task) { Rake::Task["graph_mem:canonicalize_relations"] }
  let(:suffix) { SecureRandom.hex(3) }
  let!(:variant) do
    from = MemoryEntity.create!(name: "SynthService #{suffix}", entity_type: "Service")
    to = MemoryEntity.create!(name: "SynthWidget #{suffix}", entity_type: "Component")
    relation = MemoryRelation.create!(from_entity: from, to_entity: to, relation_type: "synth_placeholder_#{suffix}")
    relation.update_column(:relation_type, "imports")
    relation
  end

  before do
    Rake::Task.define_task(:environment) unless Rake::Task.task_defined?("environment")
    Rake::Task["graph_mem:canonicalize_relations"].clear if Rake::Task.task_defined?("graph_mem:canonicalize_relations")
    load Rails.root.join("lib/tasks/graph_mem.rake")
  end

  after do
    task.reenable
    ENV.delete("DRY_RUN")
    ENV.delete("VERBOSE")
  end

  it "prints counts only with DRY_RUN=1 and writes nothing" do
    ENV["DRY_RUN"] = "1"

    expect { task.invoke }.to output(/\ARelation types \(dry run: nothing written\): scanned 1, unchanged 0, case_only 0, retyped 1,/).to_stdout
    expect(variant.reload.relation_type).to eq("imports")
    expect(MaintenanceReport.where(report_type: "relation_type_sweep")).to be_empty
  end

  it "canonicalizes, prints the counts and the report id, and lists changes with VERBOSE=1" do
    ENV["VERBOSE"] = "1"

    expect { task.invoke }.to output(/retyped 1,.*\nReport: maintenance report #\d+\n  ##{variant.id} retyped: imports -> depends_on\n/m).to_stdout
    expect(variant.reload.relation_type).to eq("depends_on")
  end
end
