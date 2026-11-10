# frozen_string_literal: true

require "rails_helper"
require "rake"

# 1.77.0: graph_mem:fact_keywords:refresh recomputes keyword paths now, for every project or one.
RSpec.describe "graph_mem:fact_keywords:refresh", type: :task do
  let(:task) { Rake::Task["graph_mem:fact_keywords:refresh"] }

  def project_with_fact(name, entity_name, content)
    root = MemoryEntity.create!(name: name, entity_type: "Project")
    entity = MemoryEntity.create!(name: entity_name, entity_type: "Class", project_id: root.id)
    fact = MemoryObservation.create!(memory_entity: entity, content: content)
    fact.update_columns(keywords: [ "stale" ], keywords_at: 1.day.ago)
    fact
  end

  before { Rails.application.load_tasks unless Rake::Task.task_defined?("graph_mem:fact_keywords:refresh") }

  after do
    ENV.delete("PROJECT")
    task.reenable
  end

  it "recomputes every active fact's path" do
    gadget = project_with_fact("Gadget Project", "SynthWidget", "SynthWidget renders frames.")
    other = project_with_fact("Other Project", "AlphaService", "AlphaService schedules renders.")

    expect { task.invoke }.to output(/2 facts marked, 2 computed/).to_stdout

    expect(gadget.reload.keywords).to eq([ "Gadget Project", "SynthWidget" ])
    expect(other.reload.keywords).to eq([ "Other Project", "AlphaService" ])
  end

  it "recomputes one project's facts with PROJECT, and refuses an unknown name" do
    gadget = project_with_fact("Gadget Project", "SynthWidget", "SynthWidget renders frames.")
    other = project_with_fact("Other Project", "AlphaService", "AlphaService schedules renders.")

    ENV["PROJECT"] = "Gadget Project"
    expect { task.invoke }.to output(/1 facts marked, 1 computed/).to_stdout
    expect(gadget.reload.keywords).to eq([ "Gadget Project", "SynthWidget" ])
    expect(other.reload.keywords).to eq([ "stale" ])

    task.reenable
    ENV["PROJECT"] = "Missing Project"
    expect { task.invoke }.to raise_error(SystemExit).and output(/no Project root named "Missing Project"/).to_stderr
  end
end
