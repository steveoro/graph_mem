# frozen_string_literal: true

require "rails_helper"
require "tmpdir"
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
    Dir.mktmpdir do |root|
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
    Dir.mktmpdir do |root|
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
    Dir.mktmpdir do |root|
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
    Dir.mktmpdir do |root|
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
end
