# frozen_string_literal: true

require "rails_helper"

# SubprocessGuard (spec/support/llm.rb): app code never starts a process. Each call is evaluated
# with a synthetic file name, so no file is written under app/ or lib/.
RSpec.describe SubprocessGuard do
  def call_from(relative_path, code)
    eval(code, binding, Rails.root.join(relative_path).to_s, 1) # rubocop:disable Security/Eval
  end

  {
    "system" => 'system("true")',
    "Kernel.system" => 'Kernel.system("true")',
    "spawn" => 'spawn("true")',
    "a backtick" => "`true`",
    "%x" => "%x(true)",
    "Process.spawn" => 'Process.spawn("true")',
    "IO.popen" => 'IO.popen(%w[true]) { |io| io.read }',
    "Open3.capture2" => 'Open3.capture2("true")',
    "Open3.popen3" => 'Open3.popen3("true") { |*| nil }'
  }.each do |label, code|
    it "refuses #{label} called from a file under app/ or lib/" do
      expect { call_from("app/services/synth_widget_runner.rb", code) }
        .to raise_error(SubprocessGuard::Blocked, %r{called from app/services/synth_widget_runner\.rb:1: app code never starts a process})
      expect { call_from("lib/graph_mem/synth_widget_runner.rb", code) }.to raise_error(SubprocessGuard::Blocked)
    end
  end

  it "lets specs, bin/ and the operator rake tasks under lib/tasks/ start a process" do
    expect(system("true")).to be(true)
    expect(Open3.capture2("echo", "ok").first).to eq("ok\n")
    expect(call_from("bin/synth_tool", 'system("true")')).to be(true)
    expect(call_from("lib/tasks/synth_widget.rake", 'system("true")')).to be(true)
  end

  it "keeps Kernel#system private and checks nothing outside an example" do
    expect(Object.new.respond_to?(:system)).to be(false)
    described_class.active = false
    expect(call_from("app/services/synth_widget_runner.rb", 'system("true")')).to be(true)
  ensure
    described_class.active = true
  end

  it "checks paths in this repo only" do
    expect(described_class.guarded_path?("/path/to/gems/rake/lib/rake/file_utils.rb")).to be(false)
    expect(described_class.guarded_path?(Rails.root.join("spec/bin/up_spec.rb").to_s)).to be(false)
    expect(described_class.guarded_path?(Rails.root.join("app/jobs/project_scan_job.rb").to_s)).to be(true)
  end
end
