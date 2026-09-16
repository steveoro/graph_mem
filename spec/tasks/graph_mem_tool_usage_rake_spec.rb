# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "graph_mem:tool_usage", type: :task do
  after do
    Rake::Task["graph_mem:tool_usage"].reenable
    ENV["DAYS"] = @original_days
  end

  let(:report) do
    {
      total_calls: 3,
      tools: [
        {
          tool_name: "get_context",
          call_count: 3,
          share_percent: 100.0,
          error_count: 1,
          error_rate_percent: 33.33,
          errors_by_category: { "validation" => 1 },
          p50_ms: 2,
          p95_ms: 8
        },
        {
          tool_name: "never_called",
          call_count: 0,
          share_percent: 0.0,
          error_count: 0,
          error_rate_percent: 0.0,
          errors_by_category: {},
          p50_ms: nil,
          p95_ms: nil
        }
      ]
    }
  end

  before do
    Rake::Task.define_task(:environment) unless Rake::Task.task_defined?("environment")
    Rake::Task["graph_mem:tool_usage"].clear if Rake::Task.task_defined?("graph_mem:tool_usage")
    load Rails.root.join("lib/tasks/graph_mem.rake")
    @original_days = ENV["DAYS"]
    ENV.delete("DAYS")
  end

  it "prints a 30-day report by default" do
    expect(ToolUsageReport).to receive(:call) do |since:|
      expect(since).to be_within(2.seconds).of(30.days.ago)
      report
    end

    expect {
      Rake::Task["graph_mem:tool_usage"].invoke
    }.to output(/Total calls: 3.*get_context.*validation=1.*Never called: never_called/m).to_stdout
  end

  it "supports all recorded history" do
    ENV["DAYS"] = "all"
    expect(ToolUsageReport).to receive(:call).with(since: nil).and_return(report)

    expect {
      Rake::Task["graph_mem:tool_usage"].invoke
    }.to output(/for all recorded history/).to_stdout
  end
end
