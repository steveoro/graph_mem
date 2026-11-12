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

# 1.83.0: the LLM words, refreshed on demand and counted read-only.
RSpec.describe "graph_mem:fact_keywords:llm_refresh and llm_report", type: :task do
  let(:refresh) { Rake::Task["graph_mem:fact_keywords:llm_refresh"] }
  let(:report) { Rake::Task["graph_mem:fact_keywords:llm_report"] }
  let(:provider) do
    FakeProvider.new do |prompt, **|
      ids = JSON.parse(prompt.to_s[/STATEMENTS:\n(\[.*\])/m, 1]).map { |entry| entry["id"].to_s }
      { ok: true, done_reason: "stop", error: nil, latency_ms: 1.0, text: ids.to_h { |id| [ id, %w[frame] ] }.to_json }
    end
  end

  before { Rails.application.load_tasks unless Rake::Task.task_defined?("graph_mem:fact_keywords:llm_refresh") }

  after do
    ENV.delete("PROJECT")
    [ refresh, report ].each(&:reenable)
  end

  def fact_in(project_name, entity_name)
    root = MemoryEntity.find_or_create_by!(name: project_name, entity_type: "Project")
    entity = MemoryEntity.create!(name: entity_name, entity_type: "Class", project_id: root.id)
    MemoryObservation.create!(memory_entity: entity, content: "#{entity_name} renders frames.").tap do |fact|
      fact.update_columns(keywords: [ project_name, entity_name ], keywords_at: Time.current, llm_keywords: %w[old], llm_keywords_at: 1.day.ago)
    end
  end

  it "recomputes one project's words with PROJECT" do
    gadget = fact_in("Gadget Project", "SynthWidget")
    other = fact_in("Other Project", "AlphaService")
    ENV["PROJECT"] = "Gadget Project"

    expect { with_llm_provider(provider) { refresh.invoke } }.to output(/1 facts marked, 1 computed/).to_stdout

    expect(gadget.reload.llm_keywords).to eq(%w[frame])
    expect(other.reload.llm_keywords).to eq(%w[old])
  end

  # 1.84.0: marking every fact pending with no LLM to answer would only grow the backlog.
  it "refuses to start, marking nothing, when the summary LLM can't be used" do
    fact = fact_in("Gadget Project", "SynthWidget")
    allow(Llm::Router).to receive(:usable?).and_call_original
    allow(Llm::Router).to receive(:usable?).with(:summary).and_return(false)

    expect { refresh.invoke }.to raise_error(SystemExit).and output(/the summary LLM isn't usable/).to_stderr
    expect(fact.reload.llm_keywords).to eq(%w[old])
  end

  it "counts the words read-only" do
    fact_in("Gadget Project", "SynthWidget")
    pending = fact_in("Gadget Project", "AlphaService")
    pending.update_columns(llm_keywords_at: nil)

    expect { report.invoke }.to output(/1 pending, 1 with words, 0 without/).to_stdout
    expect(pending.reload.llm_keywords_at).to be_nil
  end
end
