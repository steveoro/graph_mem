# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "graph_mem:export_sql and graph_mem:import_sql", type: :task do
  let!(:project) { fs_project!("SynthPrj") }
  let(:path) { Rails.root.join("tmp", "sql_exchange_rake_#{SecureRandom.hex(4)}.sql").to_s }

  before do
    Rake::Task.define_task(:environment) unless Rake::Task.task_defined?("environment")
    %w[graph_mem:export_sql graph_mem:import_sql].each { |name| Rake::Task[name].clear if Rake::Task.task_defined?(name) }
    load Rails.root.join("lib/tasks/graph_mem.rake")
    fs_member!(project, "SynthWidget", "Component")
  end

  after { FileUtils.rm_f(path) }

  def with_env(env)
    saved = env.keys.to_h { |key| [ key, ENV.fetch(key, nil) ] }
    env.each { |key, value| ENV[key] = value }
    yield
  ensure
    saved.each { |key, value| ENV[key] = value }
  end

  def run_task(name, env = {}, *args)
    with_env(env) { expect { Rake::Task[name].execute(Rake::TaskArguments.new([ :name ], args)) }.to output.to_stdout }
  end

  it "exports to OUT, previews with DRY_RUN=1 without writing, then imports" do
    run_task("graph_mem:export_sql", { "OUT" => path }, "SynthPrj")
    expect(File.read(path)).to start_with("-- graph_mem-sql v1\n")
    sql_delete_tree!(project)

    expect { run_task("graph_mem:import_sql", { "FILE" => path, "DRY_RUN" => "1" }) }.not_to change(MemoryEntity, :count)
    expect { run_task("graph_mem:import_sql", { "FILE" => path }) }.to change(MemoryEntity, :count).by(2)
    expect(MemoryEntity.find_by!(name: "SynthWidget").project_id).to eq(MemoryEntity.find_by!(name: "SynthPrj").id)
  end

  it "queues the follow-up after a real run only, recording FULL=1 for it" do
    run_task("graph_mem:export_sql", { "OUT" => path }, "SynthPrj")
    sql_delete_tree!(project)

    expect { run_task("graph_mem:import_sql", { "FILE" => path, "DRY_RUN" => "1", "FULL" => "1" }) }.not_to have_enqueued_job(SqlImportFollowUpJob)
    expect do
      with_env("FILE" => path, "FULL" => "1") { Rake::Task["graph_mem:import_sql"].execute }
    end.to have_enqueued_job(SqlImportFollowUpJob).and output(/^Follow-up queued \(SqlImportFollowUpJob\).*then all scheduled jobs \(FULL=1\)/).to_stdout
    expect(OperationProgress.find_by!(operation_type: "import").details)
      .to include("full_maintenance" => true, "file_name" => File.basename(path), "follow_up" => { "status" => "queued" })
    expect { run_task("graph_mem:import_sql", { "FILE" => path }) }.to have_enqueued_job(SqlImportFollowUpJob)
    expect(OperationProgress.where(operation_type: "import").order(:id).last.details["full_maintenance"]).to be(false)
  end

  # The export of SynthPrj at path, with the project deleted, so an import writes its two entities.
  def export_and_delete
    run_task("graph_mem:export_sql", { "OUT" => path }, "SynthPrj")
    sql_delete_tree!(project)
  end

  it "after the commit, prints a follow-up that couldn't be queued as failed with how to recover, never as a refusal" do
    export_and_delete
    allow(SqlImportFollowUpJob).to receive(:perform_later).and_raise(ActiveRecord::StatementInvalid, "queue down")

    expect do
      with_env("FILE" => path) { Rake::Task["graph_mem:import_sql"].execute }
    end.to output(/^Imported: operation \h{8}-/).to_stdout
      .and output(/\AFollow-up failed: ActiveRecord::StatementInvalid: queue down\nThe import is written\. The scheduled jobs embed .*perform_later/).to_stderr
    operation = OperationProgress.find_by!(operation_type: "import")
    expect(operation.details["follow_up"]).to eq("status" => "failed", "error" => "ActiveRecord::StatementInvalid: queue down")
    expect(MemoryEntity.count).to eq(2)
  end

  it "after the commit, says the import committed when completing its record fails, never that nothing was written" do
    export_and_delete
    allow(SqlImport::Flow).to receive(:finish).and_raise(ActiveRecord::StatementInvalid, "details lost")

    expect do
      with_env("FILE" => path) { Rake::Task["graph_mem:import_sql"].execute }
    end.to raise_error(SystemExit).and output(/^Imported: operation /).to_stdout
      .and output(/\AThe import committed \(operation (\h{8}-\h{4}-\h{4}-\h{4}-\h{12})\), but completing its record failed, so its follow-up was not queued: ActiveRecord::StatementInvalid: details lost\n.*perform_later\("\1"\)/).to_stderr
    expect(MemoryEntity.count).to eq(2)
  end

  it "after the commit, says the import committed when leaving the run fails, never that nothing was written" do
    export_and_delete
    fail_sql_import_after_commit!("lock release lost")

    expect do
      with_env("FILE" => path) { Rake::Task["graph_mem:import_sql"].execute }
    end.to raise_error(SystemExit).and output(/^Imported: operation /).to_stdout
      .and output(/\AThe import committed \(operation \h{8}-.*follow-up was not queued: ActiveRecord::StatementInvalid: lock release lost\n/).to_stderr
    expect(MemoryEntity.count).to eq(2)
    expect(OperationProgress.find_by!(operation_type: "import").details).not_to include("follow_up")
  end

  it "always validates: an edited file is refused and nothing is written" do
    run_task("graph_mem:export_sql", { "OUT" => path }, "SynthPrj")
    File.write(path, File.read(path).sub("'SynthWidget'", "'SynthWidgeT'"))

    expect do
      with_env("FILE" => path) { Rake::Task["graph_mem:import_sql"].execute }
    end.to raise_error(SystemExit).and output(/import refused, nothing was written: the body does not match its sha256/).to_stderr
    expect(MemoryEntity.count).to eq(2)
  end

  it "refuses a value MariaDB rejects after the grammar passed it: the database's message, no backtrace, nothing written" do
    run_task("graph_mem:export_sql", { "OUT" => path }, "SynthPrj")
    sql_delete_tree!(project)
    File.write(path, resign(File.read(path).sub("'part_of', NULL,", "'part_of', 1e999,")))
    expect(SqlImport::Validator.validate_file(path)).to be_a(SqlImport::Validator::Script)
    records = [ AuditLog.count, OperationProgress.count ]

    expect do
      with_env("FILE" => path) { Rake::Task["graph_mem:import_sql"].execute }
    end.to raise_error(SystemExit).and output(/\Aimport refused, nothing was written: Illegal double '1e999' value[^\n]*\n\z/).to_stderr
    expect([ MemoryEntity.count, MemoryRelation.count ]).to eq([ 0, 0 ])
    expect([ AuditLog.count, OperationProgress.count ]).to eq(records)
  end

  it "prints the control characters of a staged string (tab, ESC) as spaces in the affected rows" do
    fs_observe!(MemoryEntity.find_by!(name: "SynthWidget"), "Tab\there \e[31mred\e[0m")
    run_task("graph_mem:export_sql", { "OUT" => path }, "SynthPrj")
    sql_delete_tree!(project)

    expect do
      with_env("FILE" => path) { Rake::Task["graph_mem:import_sql"].execute }
    end.to output(a_string_including("Tab here  [31mred [0m").and(satisfy("has no tab or ESC") { |text| !text.match?(/[\t\e]/) })).to_stdout
  end

  it "prints a refusal that quotes a staged string without a raw control character (MariaDB escapes them in the message)" do
    fs_observe!(MemoryEntity.find_by!(name: "SynthWidget"), "A synthetic fact.", perspective: "world")
    run_task("graph_mem:export_sql", { "OUT" => path }, "SynthPrj")
    File.write(path, resign(File.read(path).sub("'world'", "'\e[31mworld'")))

    expect do
      with_env("FILE" => path) { Rake::Task["graph_mem:import_sql"].execute }
    end.to raise_error(SystemExit).and output(a_string_including('perspective "\\001B[31mworld" is not world or experience')
                                                .and(satisfy("has no ESC") { |text| !text.include?("\e") })).to_stderr
  end
end
