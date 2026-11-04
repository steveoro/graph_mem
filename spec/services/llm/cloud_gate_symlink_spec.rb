# frozen_string_literal: true

require "rails_helper"

# Agent-CLI PR4, step S: a recorded cloud_root with a symlink on its path is refused, so re-pointing
# a link at or above the recorded folder can't send another tree to the cloud. Temp dirs only.
RSpec.describe Llm::CloudGate do
  around do |example|
    Dir.mktmpdir("llm_gate_link") do |dir|
      @tmp = File.realpath(dir)
      example.run
    end
  end

  let!(:gadget) { MemoryEntity.create!(name: "Gadget Project", entity_type: "Project") }

  def mkdir(*parts) = File.join(@tmp, *parts).tap { |path| FileUtils.mkdir_p(path) }

  def scan_allowed?(root) = described_class.allowed?(Llm::Scope.for_scan(project_root: root, project_name: "Gadget Project"))

  it "refuses a cloud_root that is a symlink, even when the scan names the same path" do
    real = mkdir("real")
    link = File.join(@tmp, "link").tap { |path| File.symlink(real, path) }
    gadget.update!(cloud_allowed: true, cloud_root: link)

    expect(described_class.real_path?(link)).to be(false)
    expect(scan_allowed?(link)).to be(false)
    expect(described_class.allowed?(Llm::Scope.for_scan("Gadget Project", project_root: link))).to be(false)
  end

  it "refuses once a directory above the recorded folder is re-pointed to another tree" do
    mkdir("first", "app")
    mkdir("second", "app")
    File.symlink(File.join(@tmp, "first"), File.join(@tmp, "current"))
    recorded = File.join(@tmp, "current", "app")
    gadget.update!(cloud_allowed: true, cloud_root: recorded)

    expect(scan_allowed?(recorded)).to be(false)
    File.unlink(File.join(@tmp, "current"))
    File.symlink(File.join(@tmp, "second"), File.join(@tmp, "current"))
    expect(scan_allowed?(recorded)).to be(false)
    expect(described_class.allowed?(Llm::Scope.for_scan("Gadget Project", project_root: recorded))).to be(false)
  end

  it "allows the realpath recorded when Cloud was turned on" do
    real = mkdir("first", "app")
    gadget.update!(cloud_allowed: true, cloud_root: real)

    expect(described_class.real_path?(real)).to be(true)
    expect(scan_allowed?(real)).to be(true)
  end

  it "refuses a relative or unnormalized cloud_root" do
    %W[relative/app #{@tmp}/first/../first/app #{@tmp}/./app #{@tmp}/app/].each do |root|
      expect(described_class.real_path?(root)).to be(false)
    end
    expect(described_class.real_path?(nil)).to be(false)
  end
end
