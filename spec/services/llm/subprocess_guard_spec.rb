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
    "Open3.popen3" => 'Open3.popen3("true") { |*| nil }',
    # A missing command: if the guard let these through they raise ENOENT instead of replacing
    # or forking the spec process.
    "exec" => 'exec("/nonexistent/synth-widget-cmd")',
    "Process.exec" => 'Process.exec("/nonexistent/synth-widget-cmd")',
    "fork" => "fork { exit!(0) }",
    "Process.fork" => "Process.fork { exit!(0) }",
    "PTY.spawn" => 'PTY.spawn("/nonexistent/synth-widget-cmd")',
    "open(\"|cmd\")" => 'open("|/nonexistent/synth-widget-cmd")',
    "IO.read(\"|cmd\")" => 'IO.read("|/nonexistent/synth-widget-cmd")',
    "IO.readlines(\"|cmd\")" => 'IO.readlines("|/nonexistent/synth-widget-cmd")',
    "IO.write(\"|cmd\")" => 'IO.write("|/nonexistent/synth-widget-cmd", "x")'
  }.each do |label, code|
    it "refuses #{label} called from a file under app/ or lib/" do
      expect { call_from("app/services/synth_widget_runner.rb", code) }
        .to raise_error(SubprocessGuard::Blocked, %r{called from app/services/synth_widget_runner\.rb:1: app code never starts a process})
      expect { call_from("lib/graph_mem/synth_widget_runner.rb", code) }.to raise_error(SubprocessGuard::Blocked)
    end
  end

  it "lets specs, bin/ and lib/tasks/db_utils.rake start a process, but not another rake file" do
    expect(system("true")).to be(true)
    expect(Open3.capture2("echo", "ok").first).to eq("ok\n")
    expect(call_from("bin/synth_tool", 'system("true")')).to be(true)
    expect(call_from("lib/tasks/db_utils.rake", 'system("true")')).to be(true)
    expect { call_from("lib/tasks/synth_widget.rake", 'system("true")') }.to raise_error(SubprocessGuard::Blocked)
  end

  it "judges the nearest repo frame, so app code can't start a process through a gem's helper" do
    Dir.mktmpdir("synth_gem") do |dir|
      helper = File.join(dir, "synth_gem_helper.rb")
      File.write(helper, "module SynthGemHelper\n  def self.run = system(\"true\")\nend\n")
      load helper

      expect { call_from("app/services/synth_widget_runner.rb", "SynthGemHelper.run") }
        .to raise_error(SubprocessGuard::Blocked, %r{from app/services/synth_widget_runner\.rb:1})
      expect(SynthGemHelper.run).to be(true)
    ensure
      Object.send(:remove_const, :SynthGemHelper) if defined?(SynthGemHelper)
    end
  end

  it "checks open and IO.read only for a \"|cmd\" argument" do
    expect(call_from("app/services/synth_widget_runner.rb", "IO.read(#{__FILE__.dump}).size")).to be_positive
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
    expect(described_class.guarded_path?(Rails.root.join("lib/tasks/db_utils.rake").to_s)).to be(false)
  end
end
