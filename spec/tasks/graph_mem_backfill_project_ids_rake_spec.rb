# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "graph_mem:backfill_project_ids", type: :task do
  before do
    Rake::Task.define_task(:environment) unless Rake::Task.task_defined?("environment")
    Rake::Task["graph_mem:backfill_project_ids"].clear if Rake::Task.task_defined?("graph_mem:backfill_project_ids")
    load Rails.root.join("lib/tasks/graph_mem.rake")
  end

  after { Rake::Task["graph_mem:backfill_project_ids"].reenable }

  it "invokes the backfill and exits 0 on a clean run" do
    backfill = instance_double(ProjectIdBackfill)
    allow(ProjectIdBackfill).to receive(:new).and_return(backfill)
    allow(backfill).to receive(:run)

    expect { Rake::Task["graph_mem:backfill_project_ids"].invoke }.not_to raise_error
    expect(backfill).to have_received(:run).with(dry_run: false)
  end

  it "aborts with an actionable dedupe hint when the apply hits a scope conflict" do
    occupying = MemoryEntity.create!(name: "StaleDup", entity_type: "Task")
    error = ActiveRecord::RecordNotUnique.new(
      "Duplicate entry '0-StaleDup' for key 'index_memory_entities_on_project_scope_and_name'"
    )
    backfill = instance_double(ProjectIdBackfill)
    allow(ProjectIdBackfill).to receive(:new).and_return(backfill)
    allow(backfill).to receive(:run).and_raise(error)

    expect {
      expect {
        Rake::Task["graph_mem:backfill_project_ids"].invoke
      }.to raise_error(SystemExit)
    }.to output(/StaleDup.*no longer part of.*id #{occupying.id}.*re-run.*raw error: Duplicate entry/m).to_stderr
  end

  it "falls back to the raw message when the key format is unrecognized" do
    error = ActiveRecord::RecordNotUnique.new("some other uniqueness violation")
    hint = ProjectIdBackfill.conflict_hint(error)
    expect(hint).to eq("some other uniqueness violation")
  end
end
