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
    expect { run_task("graph_mem:import_sql", { "FILE" => path, "FULL" => "1" }) }.to have_enqueued_job(SqlImportFollowUpJob)
    expect(OperationProgress.find_by!(operation_type: "import").details)
      .to include("full_maintenance" => true, "file_name" => File.basename(path), "follow_up" => { "status" => "queued" })
    expect { run_task("graph_mem:import_sql", { "FILE" => path }) }.to have_enqueued_job(SqlImportFollowUpJob)
    expect(OperationProgress.where(operation_type: "import").order(:id).last.details["full_maintenance"]).to be(false)
  end

  it "always validates: an edited file is refused and nothing is written" do
    run_task("graph_mem:export_sql", { "OUT" => path }, "SynthPrj")
    File.write(path, File.read(path).sub("'SynthWidget'", "'SynthWidgeT'"))

    expect do
      with_env("FILE" => path) { Rake::Task["graph_mem:import_sql"].execute }
    end.to raise_error(SystemExit).and output(/import refused, nothing was written: the body does not match its sha256/).to_stderr
    expect(MemoryEntity.count).to eq(2)
  end
end
