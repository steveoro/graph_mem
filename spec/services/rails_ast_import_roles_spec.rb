# frozen_string_literal: true

require "rails_helper"
require "tmpdir"
require "json"

# 1.74.0: "specific beats generic" in rails_ast imports. The same name in one project typed Class or
# Module once and a Rails role type (Model) once is one entity of the role type, never a failure.
RSpec.describe "Rails AST import with Rails role types" do
  def write(dir)
    FileUtils.mkdir_p(File.join(dir, "app/models/gadget"))
    File.write(File.join(dir, "app/models/application_record.rb"), "class ApplicationRecord < ActiveRecord::Base\nend\n")
    File.write(File.join(dir, "app/models/gadget/badge.rb"), <<~RUBY)
      module Gadget
        class Badge < ApplicationRecord
          belongs_to :season
        end
      end
    RUBY
    File.write(File.join(dir, "app/models/gadget/season.rb"), "module Gadget\n  class Season < ApplicationRecord\n  end\nend\n")
  end

  # The extractor's payload, optionally with the role types turned back into Class (an import made
  # before 1.74.0).
  def import(dir, generic: false)
    payload = RailsAstExtractor.extract(dir, project_name: "Gadget Project")
    payload["nodes"].each { |node| node["entity_type"] = "Class" if generic && node["entity_type"] == "Model" }
    result = GraphifyImporter.new(JSON.generate(payload), project_name: "Gadget Project").translate
    match = ImportMatchingStrategy.new.match(result.import_data)
    ImportExecutionStrategy.new.execute(result.import_data, GraphifyImporter.headless_decisions(match[:match_results]))
  end

  def badges = MemoryEntity.where(name: "Gadget::Badge")

  it "imports models as Model entities, named files by path" do
    Dir.mktmpdir do |dir|
      write(dir)

      expect(import(dir).success).to be(true)

      expect(badges.pluck(:entity_type)).to eq(%w[Model])
      expect(MemoryEntity.where(entity_type: "File").pluck(:name)).to include("app/models/gadget/badge.rb")
    end
  end

  it "upgrades an earlier import's Class to Model in place, with no second entity and no review rows" do
    Dir.mktmpdir do |dir|
      write(dir)
      expect(import(dir, generic: true).success).to be(true)
      expect(badges.pluck(:entity_type)).to eq(%w[Class])
      badge_id = badges.sole.id

      report = import(dir)

      expect(report.success).to be(true)
      expect(badges.pluck(:id, :entity_type)).to eq([ [ badge_id, "Model" ] ])
      expect(MemoryRelation.where(from_entity_id: badge_id, relation_type: "belongs_to")).to exist
      rows = MaintenanceReportRow.by_report_type("scan_review").where("JSON_EXTRACT(payload, '$.entity_id') = ?", badge_id)
      expect(rows.map(&:payload)).to eq([])
    end
  end

  it "keeps a stored Model when a generic Class declaration of the same name lands on it" do
    Dir.mktmpdir do |dir|
      write(dir)
      expect(import(dir).success).to be(true)
      badge_id = badges.sole.id

      expect(import(dir, generic: true).success).to be(true)

      expect(badges.pluck(:id, :entity_type)).to eq([ [ badge_id, "Model" ] ])
    end
  end
end

RSpec.describe ImportEntityResolver, ".resolved_code_type" do
  it "lets a specific role beat a generic code type, never the other way round" do
    expect(described_class.resolved_code_type("Class", "Model")).to eq("Model")
    expect(described_class.resolved_code_type("Module", "Concern")).to eq("Concern")
    expect(described_class.resolved_code_type("Model", "Class")).to eq("Model")
    expect(described_class.resolved_code_type("Helper", "Module")).to eq("Helper")
  end

  it "keeps the incoming type between two generic or two specific types (callers decide when to retype)" do
    expect(described_class.resolved_code_type("Class", "Module")).to eq("Module")
    expect(described_class.resolved_code_type("Model", "Model")).to eq("Model")
  end

  it "groups Class, Module and the role types as one sibling family, and nothing else" do
    expect(described_class.sibling_types("Class")).to include("Module", "Model", "Controller", "Strategy")
    expect(described_class.sibling_types("Model")).to include("Class", "Module")
    expect(described_class.sibling_types("Issue")).to eq([])
  end
end
