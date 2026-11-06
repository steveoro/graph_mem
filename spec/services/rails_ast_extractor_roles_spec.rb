# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

# 1.74.0: RailsAstExtractor reads every Ruby dir of app/ (but assets, javascript, views) and lib/
# (but tasks, generators, templates, assets), types each constant with its Rails role, keys File
# nodes by path, and exposes its declarations and unreadable files. A synthetic engine tree.
RSpec.describe RailsAstExtractor, "Rails roles" do
  let(:files) do
    {
      "app/models/application_record.rb" => "class ApplicationRecord < ActiveRecord::Base\n  self.abstract_class = true\nend\n",
      "app/models/gadget.rb" => "module Gadget\nend\n",
      "app/models/gadget/badge.rb" => "module Gadget\n  class Badge < ApplicationRecord\n    include Trackable\n    class Error < StandardError; end\n  end\nend\n",
      "app/models/gadget/trackable.rb" => "module Gadget\n  module Trackable\n    extend ActiveSupport::Concern\n  end\nend\n",
      "app/models/concerns/framed.rb" => "module Framed\nend\n",
      "app/strategies/gadget/importers/badge.rb" => "module Gadget\n  module Importers\n    class Badge\n      def call; end\n    end\n  end\nend\n",
      "app/controllers/application_controller.rb" => "class ApplicationController < ActionController::Base\nend\n",
      "app/controllers/gadget/widgets_controller.rb" => "module Gadget\n  class WidgetsController < ApplicationController\n    def index; end\n  end\nend\n",
      "app/helpers/gadget/widgets_helper.rb" => "module Gadget\n  module WidgetsHelper\n  end\nend\n",
      "app/jobs/application_job.rb" => "class ApplicationJob < ActiveJob::Base\nend\n",
      "app/jobs/gadget/render_job.rb" => "module Gadget\n  class RenderJob < ApplicationJob\n  end\nend\n",
      "app/mailers/gadget/notice_mailer.rb" => "module Gadget\n  class NoticeMailer < ActionMailer::Base\n  end\nend\n",
      "lib/gadget/frame_buffer.rb" => "module Gadget\n  class FrameBuffer\n  end\nend\n",
      "lib/gadget/legacy_badge.rb" => "module Gadget\n  class LegacyBadge < Badge\n  end\nend\n",
      "lib/tasks/gadget_tasks.rb" => "class GadgetTask\nend\n",
      "app/assets/config/manifest.rb" => "class AssetThing\nend\n",
      "app/views/gadget/widgets/index.html.rb" => "class ViewThing\nend\n",
      "config/routes.rb" => "Gadget::Engine.routes.draw do\n  get \"/gizmos\", to: \"gizmos#index\"\nend\n"
    }
  end

  def write(dir, extra = {})
    files.merge(extra).each do |path, content|
      full = File.join(dir, path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, content)
    end
  end

  def types(result)
    result["nodes"].reject { |node| %w[File Method Route].include?(node["entity_type"]) }.to_h { |node| [ node["label"], node["entity_type"] ] }
  end

  it "types each constant with its Rails role, by directory, concern and superclass chain" do
    Dir.mktmpdir do |dir|
      write(dir)

      typed = types(described_class.extract(dir, project_name: "Gadget"))

      expect(typed).to include("ApplicationRecord" => "Model", "Gadget" => "Module", "Gadget::Badge" => "Model",
                               "Gadget::Badge::Error" => "Class", "Gadget::Trackable" => "Concern", "Framed" => "Concern",
                               "Gadget::Importers" => "Module", "Gadget::Importers::Badge" => "Strategy",
                               "ApplicationController" => "Controller", "Gadget::WidgetsController" => "Controller",
                               "Gadget::WidgetsHelper" => "Helper", "Gadget::RenderJob" => "Job",
                               "Gadget::NoticeMailer" => "Mailer", "Gadget::FrameBuffer" => "Class",
                               "Gadget::LegacyBadge" => "Model")
      expect(typed.keys).not_to include("GadgetTask", "AssetThing", "ViewThing")
    end
  end

  it "types a routes-only controller stub as a Controller, and gives each constant one node" do
    Dir.mktmpdir do |dir|
      write(dir)

      result = described_class.extract(dir, project_name: "Gadget")

      expect(types(result)).to include("GizmosController" => "Controller")
      labels = result["nodes"].reject { |node| node["entity_type"] == "File" }.map { |node| [ node["entity_type"], node["label"] ] }
      expect(labels.tally.select { |_pair, count| count > 1 }).to be_empty
      badge = result["nodes"].find { |node| node["label"] == "Gadget::Badge" }
      expect(result["links"].select { |link| link["source"] == badge["id"] && link["relation"] == "mixes_in" }.size).to eq(1)
    end
  end

  it "keeps two same-named files in different dirs as two File nodes, each containing its own class" do
    Dir.mktmpdir do |dir|
      write(dir)

      result = described_class.extract(dir, project_name: "Gadget")

      by_id = result["nodes"].to_h { |node| [ node["id"], node ] }
      files = result["nodes"].select { |node| node["entity_type"] == "File" && node["label"] == "badge.rb" }
      expect(files.map { |node| node["source_file"] }).to contain_exactly("app/models/gadget/badge.rb", "app/strategies/gadget/importers/badge.rb")
      contained = files.to_h do |file|
        children = result["links"].select { |link| link["relation"] == "contains" && link["source"] == file["id"] }
        [ file["source_file"], children.map { |link| by_id[link["target"]]["label"] } ]
      end
      expect(contained["app/models/gadget/badge.rb"]).to eq([ "Gadget" ])
      expect(contained["app/strategies/gadget/importers/badge.rb"]).to eq([ "Gadget" ])
    end
  end

  it "reads only the given dirs and kept files, and lists declarations and unreadable files" do
    Dir.mktmpdir do |dir|
      write(dir, "app/models/gadget/broken.rb" => "class Broken <\n")
      extractor = described_class.new(dir, project_name: "Gadget", dirs: %w[app/models],
                                           keep: ->(path) { !path.end_with?("concerns/framed.rb") })

      typed = types(extractor.extract)

      expect(typed.keys).to include("Gadget::Badge")
      expect(typed.keys).not_to include("Framed", "Gadget::WidgetsController")
      expect(extractor.declarations["Gadget::Badge"]).to eq([ { file: "app/models/gadget/badge.rb", line: "L2", kind: "Class", type: "Model" } ])
      expect(extractor.unreadable_files).to eq([ "app/models/gadget/broken.rb" ])
    end
  end
end
