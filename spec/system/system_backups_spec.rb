# frozen_string_literal: true

require "rails_helper"

# UI-7 S4 in a browser: the typed restore card. Its button stays disabled until the file name is
# typed (typed_confirm_controller.js); the server check is the guard (request spec). The backup
# folder is a Dir.mktmpdir and the file is synthetic; the restore itself is stubbed.
RSpec.describe "System › Backups", type: :system do
  let(:file_name) { "202601011200_synth.sql.bz2" }

  around do |example|
    Dir.mktmpdir("synth_backups") do |dir|
      AppSettings.backup_folder_path = dir
      File.write(File.join(dir, file_name), "synthetic backup")
      example.run
    ensure
      AppSettings.where(var: "backup_folder_path").delete_all
      AppSettings.clear_cache
    end
  end

  before do
    ENV["OPERATOR_USERNAME"] = OperatorAuthHelpers::TEST_OPERATOR_USERNAME
    ENV["OPERATOR_PASSWORD"] = OperatorAuthHelpers::TEST_OPERATOR_PASSWORD
    sign_in_through_form
    expect(page).to have_current_path(root_path, wait: 5)
  end

  it "enables Restore only once the file name is typed" do
    restored = []
    allow_any_instance_of(BackupFileService).to receive(:restore!) { |_service, name| restored << name }
    allow(GraphMem::OfficialMcp).to receive(:refresh_access!)

    visit system_backups_path
    wait_for_stimulus
    find("[data-testid='typed-confirm-open-restore-#{file_name}']").click
    submit = find("[data-testid='typed-confirm-submit-restore-#{file_name}']")
    expect(submit).to be_disabled

    input = find("[data-testid='typed-confirm-input-restore-#{file_name}']")
    input.fill_in(with: "202601011200_synth")
    expect(submit).to be_disabled
    input.fill_in(with: file_name)
    expect(submit).not_to be_disabled

    submit.click
    expect(page).to have_text("Database restored from #{file_name}")
    expect(restored).to eq([ file_name ])
    expect(csp_console_errors).to be_empty
  end
end
