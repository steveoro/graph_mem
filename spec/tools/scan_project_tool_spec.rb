# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

RSpec.describe ScanProjectTool, type: :model do
  let(:tool) { described_class.new }

  describe "class methods" do
    describe ".tool_name" do
      it "returns the correct tool name" do
        expect(described_class.tool_name).to eq("scan_project")
      end
    end

    describe ".description" do
      it "returns a non-empty description" do
        expect(tool.description).to be_a(String)
        expect(tool.description).not_to be_empty
      end
    end
  end

  describe "#call" do
    it "enqueues a scan and returns a queued payload" do
      Dir.mktmpdir("scan_project_tool") do |dir|
        result = nil
        expect {
          result = tool.call(project_root: dir, mode: "initial")
        }.to have_enqueued_job(ProjectScanJob)

        expect(result[:status]).to eq("queued")
        expect(result[:scan_id]).to be_present
        expect(result[:mode]).to eq("initial")
        expect(result[:project_root]).to eq(File.expand_path(dir))
      end
    end

    it "raises InvalidArgumentsError when the project root is not a directory" do
      expect {
        tool.call(project_root: "/nonexistent/graph-mem-scan-root")
      }.to raise_error(FastMcp::Tool::InvalidArgumentsError, /not a directory/i)
    end

    it "raises InvalidArgumentsError listing allowed modes" do
      Dir.mktmpdir("scan_project_tool") do |dir|
        expect {
          tool.call(project_root: dir, mode: "bogus")
        }.to raise_error(FastMcp::Tool::InvalidArgumentsError, /initial, rescan, validate/)
      end
    end

    it "raises a generic InternalServerError when enqueue fails" do
      Dir.mktmpdir("scan_project_tool") do |dir|
        allow(ProjectScanJob).to receive(:perform_later).and_raise(StandardError.new("queue exploded"))
        allow(Rails.logger).to receive(:error)

        expect {
          tool.call(project_root: dir)
        }.to raise_error(McpGraphMemErrors::InternalServerError, /unexpected error/) do |error|
          expect(error.message).not_to include("queue exploded")
        end

        expect(Rails.logger).to have_received(:error).with(/queue exploded/)
      end
    end
  end
end
