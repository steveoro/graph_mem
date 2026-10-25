# frozen_string_literal: true

require "rails_helper"

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
    it "enqueues a scan of the resolved realpath and returns a queued payload" do
      with_scan_project do |project|
        result = nil
        expect {
          result = tool.call(project_root: project, mode: "initial")
        }.to have_enqueued_job(ProjectScanJob).with(anything, project, any_args)

        expect(result).to include(status: "queued", mode: "initial", project_root: project, warnings: [])
        expect(result[:scan_id]).to be_present
      end
    end

    it "records the scan as pending before returning, so scan_project_status finds it at once" do
      with_scan_project do |project|
        result = tool.call(project_root: project, dry_run: true)

        status = ScanProjectStatusTool.new.call(scan_id: result[:scan_id])
        expect(status).to include(scan_id: result[:scan_id], status: "pending", phase: "queued")
        expect(status[:details]).to include("project_root" => project, "dry_run" => true)
      end
    end

    {
      "/nonexistent/graph-mem-scan-root" => [ /isn't visible to graph_mem/, "not_mounted" ],
      "%{home}/.ssh" => [ /hidden or protected folder/, "denied" ],
      "%{home}/Other/x" => [ /outside the scan filter/, "outside_filter" ],
      "%{home}/Projects/missing" => [ /was not found/, "not_found" ]
    }.each do |template, (message, code)|
      it "refuses #{template} with a validation error and code #{code}" do
        with_scan_home do |home|
          path = format(template, home: home)
          FileUtils.mkdir_p(path) if path.end_with?(".ssh", "/x")

          expect { tool.call(project_root: path) }.to raise_error(McpGraphMemErrors::InvalidArguments, message) { |error|
            expect(ToolError.envelope(error, tool_name: "scan_project")).to include("category" => "validation", "code" => code)
          }
          expect(OperationProgress.where(operation_type: "project_scan")).to be_empty
        end
      end
    end

    it "refuses a finished scan's scan_id with code scan_id_not_resumable" do
      with_scan_project do |project|
        scan_id = SecureRandom.uuid
        OperationProgress.create!(operation_type: "project_scan", operation_id: scan_id, status: "failed",
                                  total_count: 6, current_count: 2, percentage: 33)

        expect {
          tool.call(project_root: project, scan_id: scan_id)
        }.to raise_error(McpGraphMemErrors::InvalidArguments, /is failed, not paused/) { |error|
          expect(ToolError.envelope(error)).to include("category" => "validation", "code" => "scan_id_not_resumable")
          expect(error.next_move).to include("Omit `scan_id`")
        }
      end
    end

    it "refuses file_globs that leave the project root with code invalid_file_globs" do
      with_scan_project do |project|
        expect {
          tool.call(project_root: project, file_globs: [ "/etc/*" ])
        }.to raise_error(McpGraphMemErrors::InvalidArguments, /must be relative/) { |error|
          expect(error.code).to eq("invalid_file_globs")
        }
      end
    end

    it "raises InvalidArgumentsError listing allowed modes" do
      with_scan_project do |project|
        expect {
          tool.call(project_root: project, mode: "bogus")
        }.to raise_error(GraphMem::InvalidArgumentsError, /initial, rescan, validate/)
      end
    end

    it "raises a generic InternalServerError when enqueue fails" do
      with_scan_project do |project|
        allow(ProjectScanJob).to receive(:perform_later).and_raise(StandardError.new("queue exploded"))
        allow(Rails.logger).to receive(:error)

        expect {
          tool.call(project_root: project)
        }.to raise_error(McpGraphMemErrors::InternalServerError, /unexpected error/) do |error|
          expect(error.message).not_to include("queue exploded")
        end

        expect(Rails.logger).to have_received(:error).with(/queue exploded/)
        expect(OperationProgress.where(operation_type: "project_scan")).to be_empty
      end
    end
  end
end
