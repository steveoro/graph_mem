# frozen_string_literal: true

require "rails_helper"

# The SQL import in a browser: upload a graph_mem-sql script, read the dry-run preview, ask for full
# maintenance, execute, and land on the report with the follow-up queued. Jobs don't run here (the
# test queue adapter).
RSpec.describe "SQL import", type: :system do
  let(:path) { Rails.root.join("tmp", "system_sql_import_#{SecureRandom.hex(4)}.sql") }
  let!(:sessions_before) { stored_scripts }

  def stored_scripts = Dir.glob(ImportSession::TEMP_DIR.join("*_script.sql"))

  before do
    ENV["OPERATOR_USERNAME"] = OperatorAuthHelpers::TEST_OPERATOR_USERNAME
    ENV["OPERATOR_PASSWORD"] = OperatorAuthHelpers::TEST_OPERATOR_PASSWORD
    sign_in_through_form
    expect(page).to have_current_path(root_path, wait: 5)
  end

  after do
    FileUtils.rm_f(path)
    (stored_scripts - sessions_before).each { |file| ImportSession.cleanup(File.basename(file, "_script.sql")) }
  end

  it "previews the script, executes it with full maintenance and shows the report" do
    project = fs_project!("SynthPrj")
    fs_member!(project, "SynthWidget", "Component")
    File.write(path, sql_export(project))
    sql_delete_tree!(project)

    visit new_projects_import_path
    attach_file "file", path
    click_on "Upload for review"

    expect(page).to have_css("[data-testid='sql-import-preview']")
    within("[data-testid='sql-import-summary-memory_entities']") { expect(page).to have_css("td", text: "2", count: 1) }
    expect(page).to have_link("System › Backups")
    expect(MemoryEntity.count).to eq(0)

    check "Run full maintenance now"
    click_on "Execute import"

    expect(page).to have_css("[data-testid='import-report']")
    expect(page).to have_css("[data-testid='sql-import-follow-up-status']", text: "queued")
    expect(page).to have_text("Full maintenance is requested")
    expect(MemoryEntity.where(name: %w[SynthPrj SynthWidget]).count).to eq(2)
    expect(OperationProgress.find_by!(operation_type: "import").details["full_maintenance"]).to be(true)
  end
end
