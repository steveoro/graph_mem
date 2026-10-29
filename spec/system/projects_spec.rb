# frozen_string_literal: true

require "rails_helper"

# UI-6 in a browser: a dry-run scan of a Dir.mktmpdir root from the one scan form (live path
# check included) to its detail page's live progress, and an export from the picker to its
# download link. Jobs don't run here (the test queue adapter); the spec plays the job's part by
# updating the OperationProgress and broadcasting it.
RSpec.describe "Projects & Data", type: :system do
  before do
    ENV["OPERATOR_USERNAME"] = OperatorAuthHelpers::TEST_OPERATOR_USERNAME
    ENV["OPERATOR_PASSWORD"] = OperatorAuthHelpers::TEST_OPERATOR_PASSWORD
    sign_in_through_form
    expect(page).to have_current_path(root_path, wait: 5)
  end

  # The channel subscribes asynchronously: broadcast until the page shows the update.
  def broadcast_until(operation, text)
    10.times do
      OperationProgressBroadcaster.call(operation)
      return if page.has_text?(text, wait: 0.5)
    end
    expect(page).to have_text(text)
  end

  it "checks the path live, queues a dry-run scan and follows its progress" do
    with_scan_project("alpha") do |project|
      visit new_projects_scan_path
      wait_for_stimulus
      find("[data-testid='scan-path']").fill_in(with: "#{project}/missing")
      expect(page).to have_css("[data-testid='scan-check-result'][data-code='not_found']", wait: 5)
      find("[data-testid='scan-path']").fill_in(with: project)
      expect(page).to have_css("[data-testid='scan-check-result'][data-code='ok']", wait: 5)

      fill_in "project_name", with: "Alpha Service"
      check "dry_run"
      click_on "Start scan"

      expect(page).to have_css("[data-testid='scan-detail']")
      operation = OperationProgress.find_by!(operation_type: "project_scan")
      expect(operation.details).to include("project_root" => project, "dry_run" => true)
      expect(page).to have_css("[data-testid='scan-status']", text: /pending/i)

      operation.update!(status: "running", phase: "reading_files", percentage: 40, message: "Reading SynthWidget files")
      broadcast_until(operation, "Reading SynthWidget files")
      expect(page).to have_css("[data-testid='scan-status']", text: /running/i)
      expect(page).to have_text("40%")
    end
  end

  it "exports a root and shows the download link when the export completes" do
    alpha = MemoryEntity.create!(name: "Alpha Service", entity_type: "Project")

    visit projects_exports_path
    wait_for_stimulus
    check "export_root_#{alpha.id}"
    click_on "Export selected"

    expect(page).to have_css("[data-testid='export-detail']")
    export = OperationProgress.find_by!(operation_type: "export")
    expect(page).to have_no_css("[data-testid='export-download']", visible: true)

    FileUtils.mkdir_p(ExportJob::TEMP_DIR)
    File.write(ExportJob.download_path(export.operation_id), { root_nodes: [ { name: "Alpha Service" } ] }.to_json)
    export.complete!(current: 1, message: "Export complete")
    broadcast_until(export, "Export complete")
    expect(page).to have_css("[data-testid='export-download']", visible: true)
  ensure
    FileUtils.rm_f(ExportJob.download_path(export.operation_id)) if export
  end
end
