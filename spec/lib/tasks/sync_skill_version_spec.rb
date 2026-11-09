# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "graph_mem:sync_skill_version", type: :task do
  let(:skill_copy) { Rails.root.join("tmp", "sync_skill_version_#{SecureRandom.hex(4)}_SKILL.md") }
  let(:task) { Rake::Task["graph_mem:sync_skill_version"] }

  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?("graph_mem:sync_skill_version")
    FileUtils.cp(Rails.root.join("skills/graph-mem-mcp-toolset/SKILL.md"), skill_copy)
    skill_copy.write(skill_copy.read.sub(/graph-mem-version: "[^"]*"/, 'graph-mem-version: "0.0.1"'))
  end

  after do
    ENV.delete("SKILL_PATH")
    FileUtils.rm_f(skill_copy)
    task.reenable
  end

  it "sets metadata.graph-mem-version to GraphMem::VERSION and leaves the rest untouched" do
    before_text = skill_copy.read

    ENV["SKILL_PATH"] = skill_copy.to_s
    expect { task.invoke }.to output(/graph-mem-version = #{Regexp.escape(GraphMem::VERSION)}/).to_stdout

    after_text = skill_copy.read
    expect(YAML.safe_load(after_text.split("---", 3)[1]).dig("metadata", "graph-mem-version")).to eq(GraphMem::VERSION)
    expect(after_text.sub(GraphMem::VERSION, "0.0.1")).to eq(before_text)
  end
end
