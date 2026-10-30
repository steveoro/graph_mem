# frozen_string_literal: true

require "rails_helper"
require "fileutils"

RSpec.describe ProjectScanSkill, type: :service do
  def create_operation(root, extra = {})
    OperationProgress.create!(
      operation_type: "project_scan_skill",
      operation_id: SecureRandom.uuid,
      status: "pending",
      total_count: ProjectScanSkill::DEPTH_ORDER.size,
      current_count: 0,
      percentage: 0,
      phase: ProjectScanSkill::DEPTH_ORDER.first,
      message: "Queued",
      details: {
        project_root: root,
        project_name: "Test Project",
        aliases: "test, tp",
        depths: ProjectScanSkill::DEPTH_ORDER,
        current_depth_index: 0,
        dry_run: false
      }.merge(extra)
    )
  end

  def create_project_files(root)
    File.write(File.join(root, "README.md"), "# Test Project\n\nA test project for the skill companion.\n")
    FileUtils.mkdir_p(File.join(root, "app/controllers"))
    File.write(File.join(root, "app/controllers/test_controller.rb"), "class TestController < ApplicationController\nend\n")
    FileUtils.mkdir_p(File.join(root, "app/models"))
    File.write(File.join(root, "app/models/test.rb"), "class Test < ApplicationRecord\nend\n")
    FileUtils.mkdir_p(File.join(root, "app/views/test"))
    File.write(File.join(root, "app/views/test/index.html.erb"), "<h1>Test</h1>\n")
    FileUtils.mkdir_p(File.join(root, "config"))
    File.write(File.join(root, "config/database.yml"), "test:\n  adapter: mysql2\n")
    FileUtils.mkdir_p(File.join(root, "spec"))
    File.write(File.join(root, "spec/test_spec.rb"), "RSpec.describe 'Test' do\nend\n")
    FileUtils.mkdir_p(File.join(root, "docs"))
    File.write(File.join(root, "docs/README.md"), "# Docs\n")
  end

  it "processes one depth and pauses" do
    with_scan_project do |root|
      create_project_files(root)
      operation = create_operation(root)

      result = described_class.process!(operation)

      expect(result[:status]).to eq(:paused)
      operation.reload
      expect(operation.status).to eq("paused")
      expect(operation.details["current_depth_index"]).to eq(1)
      expect(operation.phase).to eq("architecture")
      expect(operation.percentage).to eq(20.0)
    end
  end

  it "processes all depths and completes" do
    with_scan_project do |root|
      create_project_files(root)
      operation = create_operation(root)

      ProjectScanSkill::DEPTH_ORDER.size.times do
        operation.reload
        described_class.process!(operation)
        break if operation.reload.status == "completed"
      end

      operation.reload
      expect(operation.status).to eq("completed")
      expect(operation.percentage).to eq(100.0)
      expect(operation.details["current_depth_index"]).to eq(ProjectScanSkill::DEPTH_ORDER.size)
    end
  end

  it "creates project and child entities across all depths" do
    with_scan_project do |root|
      create_project_files(root)
      operation = create_operation(root)

      ProjectScanSkill::DEPTH_ORDER.size.times do
        operation.reload
        described_class.process!(operation)
        break if operation.reload.status == "completed"
      end

      project = MemoryEntity.find_by(entity_type: "Project", name: "Test Project")
      expect(project).to be_present

      controller = MemoryEntity.find_by(entity_type: "Route", name: "TestController")
      expect(controller).to be_present
      expect(controller.memory_observations.map(&:content)).to include(a_string_matching(/test_controller/))

      model = MemoryEntity.find_by(entity_type: "Model", name: "Test")
      expect(model).to be_present
    end
  end

  it "does not persist in dry-run mode" do
    with_scan_project do |root|
      create_project_files(root)
      operation = create_operation(root, dry_run: true)

      described_class.process!(operation)

      expect(MemoryEntity.find_by(name: "Test Project")).to be_nil
    end
  end

  it "fails when project root does not exist" do
    operation = create_operation("/nonexistent/path")

    result = described_class.process!(operation)

    expect(result[:status]).to eq(:failed)
    operation.reload
    expect(operation.status).to eq("failed")
  end

  it "fails with the policy message when the folder left the subfolder filter" do
    with_scan_project do |root|
      create_project_files(root)
      operation = create_operation(root)
      write_scan_subfolders_raw("work")

      expect(described_class.process!(operation)[:status]).to eq(:failed)
      expect(operation.reload).to have_attributes(status: "failed")
      expect(operation.error_message).to include("outside the scan filter")
    end
  end

  it "never reads denylisted files or files linked from outside the project" do
    with_scan_project do |root, home|
      create_project_files(root)
      File.write(File.join(root, ".env"), "SECRET=synthetic")
      File.write(File.join(home, "outside.md"), "# outside")
      File.symlink(File.join(home, "outside.md"), File.join(root, "docs", "linked.md"))
      read = []
      allow(File).to receive(:binread).and_wrap_original { |original, path, *args| read << path.to_s; original.call(path, *args) }

      described_class.process!(create_operation(root, depths: %w[tests_and_docs]))

      expect(read).not_to include(File.join(root, ".env"), File.join(root, "docs", "linked.md"))
      expect(OperationProgress.last.counters).to include("skipped_outside_root" => 1)
    end
  end

  it "doesn't list entries of a source folder linked from outside the project" do
    with_scan_project do |root, home|
      create_project_files(root)
      outside = File.join(home, "elsewhere").tap { |dir| FileUtils.mkdir_p(File.join(dir, "secret_widget")) }
      File.symlink(outside, File.join(root, "lib"))

      described_class.process!(create_operation(root, depths: %w[architecture]))

      expect(MemoryEntity.where("name LIKE ?", "%secret_widget%")).to be_empty
    end
  end

  describe "symlinked children" do
    it "names a symlinked source child without following it" do
      with_scan_project do |root, home|
        create_project_files(root)
        outside = File.join(home, "elsewhere").tap { |dir| FileUtils.mkdir_p(File.join(dir, "secret_widget")) }
        FileUtils.mkdir_p(File.join(root, "lib"))
        File.symlink(outside, File.join(root, "lib", "outside"))
        listed = []
        allow(Dir).to receive(:children).and_wrap_original do |original, path, *args, **opts|
          listed << path.to_s
          original.call(path, *args, **opts)
        end

        described_class.process!(create_operation(root, depths: %w[architecture]))

        expect(MemoryEntity.where(name: "outside", entity_type: "Component")).to be_empty
        expect(MemoryEntity.where(name: "Outside", entity_type: "Class")).to exist
        expect(MemoryEntity.where("name LIKE ?", "%secret_widget%")).to be_empty
        expect(listed).not_to include(outside, File.join(root, "lib", "outside"))
      end
    end

    it "keeps a real source subdirectory as a Component" do
      with_scan_project do |root|
        create_project_files(root)
        FileUtils.mkdir_p(File.join(root, "lib", "synth_widget"))

        described_class.process!(create_operation(root, depths: %w[architecture]))

        expect(MemoryEntity.where(name: "synth_widget", entity_type: "Component")).to exist
      end
    end

    it "leaves a top-level symlink to an outside folder out of the top-level directories" do
      with_scan_project do |root, home|
        create_project_files(root)
        outside = File.join(home, "elsewhere").tap { |dir| FileUtils.mkdir_p(dir) }
        File.symlink(outside, File.join(root, "linked_alpha"))
        skill = described_class.new(create_operation(root, depths: %w[birds_eye]))

        dirs = skill.send(:top_level_directories)

        expect(dirs).to include("app", "docs")
        expect(dirs).not_to include("linked_alpha")
      end
    end

    it "leaves out one entry that vanishes before lstat and keeps the others" do
      with_scan_project do |root|
        create_project_files(root)
        FileUtils.mkdir_p(File.join(root, "gone_widget"))
        gone = File.join(root, "gone_widget")
        allow(File).to receive(:lstat).and_call_original
        allow(File).to receive(:lstat).with(gone).and_raise(Errno::ENOENT)

        dirs = described_class.new(create_operation(root, depths: %w[birds_eye])).send(:top_level_directories)
        # The temp folder's cleanup lstats every entry again.
        allow(File).to receive(:lstat).and_call_original

        expect(dirs).to include("app", "docs")
        expect(dirs).not_to include("gone_widget")
      end
    end
  end
end
