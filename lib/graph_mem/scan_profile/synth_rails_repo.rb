# frozen_string_literal: true

require "fileutils"
require "json"

module GraphMem
  module ScanProfile
    # The generated `synth_rails` fixture of `graph_mem:scan_profile` (1.75.0): a tiny Rails engine,
    # "gadget_engine", for the scan's Rails code map. It holds two classes named Badge (a model and an
    # importer strategy), a controller with a views folder and a layout, engine routes, a concern, a
    # job, a helper, a mailer and a Gemfile with gems. The `synth` repo stays non-Rails, so its
    # baselines stay comparable.
    #
    # Its stub answers name things the way a small model does: bare names (`Badge`, `Swimmer`), a gem
    # typed as a framework, a table-like type for a database gem. The code map maps them back onto
    # the skeleton (a bare Badge in a part that defines both Badges is dropped).
    #
    # Plain Ruby: script/scan_profile/fake_ollama.rb loads it without Rails.
    #
    #   SynthRailsRepo.write(dir)
    #   SynthRailsRepo.expected("code")[:entities] # => ["GadgetEngine::Badge", "GadgetEngine::Importers::Badge", …]
    #   SynthRailsRepo.stub_answer(prompt)         # => { text: "{…}", done_reason: "stop" }
    module SynthRailsRepo
      KEY = "synth_rails"
      PROJECT_NAME = "gadget_engine"
      PROFILES = {
        "docs" => %w[README* Gemfile docs/**/*.md],
        "code" => %w[app/**/*.rb lib/**/*.rb config/routes.rb]
      }.freeze

      ENTITIES = %w[GadgetEngine::Badge GadgetEngine::Importers::Badge GadgetEngine::Swimmer GadgetEngine::SwimmersController
                    GadgetEngine::Trackable GadgetEngine::RenderJob GadgetEngine::SwimmersHelper GadgetEngine::NoticeMailer].freeze
      RELATIONS = [ %w[GadgetEngine::Badge belongs_to GadgetEngine::Swimmer], %w[GadgetEngine::Swimmer has_many GadgetEngine::Badge],
                    %w[GadgetEngine::Badge mixes_in GadgetEngine::Trackable], %w[config/routes.rb routes_to GadgetEngine::SwimmersController],
                    %w[GadgetEngine::SwimmersController relates_to app/views/gadget_engine/swimmers] ].freeze
      EXPECTED = {
        "docs" => { entities: ENTITIES + %w[grape], relations: RELATIONS },
        "code" => { entities: ENTITIES, relations: RELATIONS }
      }.freeze

      PART_OF = { "to" => PROJECT_NAME, "type" => "part_of", "confidence" => 0.9 }.freeze

      def self.item(name, type, observation, relations = [ PART_OF ])
        { "entity" => { "name" => name, "type" => type }, "observations" => [ observation ], "relations" => relations }
      end
      private_class_method :item

      ANSWERS = {
        "README.md" => [
          item("Badge", "Concept", "A Badge rewards a swimmer's result."),
          item("Swimmer", "Model", "Swimmer holds a swimmer's details.")
        ],
        "Gemfile" => [
          item("grape", "Framework", "Grape serves the engine's API."),
          item("mysql2", "DatabaseTable", "mysql2 connects the engine to MariaDB.")
        ],
        "docs/architecture.md" => [
          item("SwimmersController", "Route", "SwimmersController lists the swimmers.",
               [ { "to" => "Swimmer", "type" => "depends_on", "confidence" => 0.8 } ])
        ],
        "app/models/gadget_engine/badge.rb" => [
          item("Badge", "Class", "Badge belongs to a swimmer.", [ PART_OF, { "to" => "Swimmer", "type" => "belongs_to", "confidence" => 0.9 } ])
        ],
        "app/models/gadget_engine/swimmer.rb" => [ item("Swimmer", "Class", "Swimmer has many badges.") ],
        "app/strategies/gadget_engine/importers/badge.rb" => [ item("Badge", "Service", "Badge imports badges from a results file.") ],
        "app/controllers/gadget_engine/swimmers_controller.rb" => [
          item("SwimmersController", "Controller", "SwimmersController renders the swimmers' index and show pages.")
        ],
        "app/jobs/gadget_engine/render_job.rb" => [ item("RenderJob", "Job", "RenderJob renders a swimmer's badge card.") ]
      }.freeze

      module_function

      # @param dir [String] an empty temp dir
      # @return [String] dir
      def write(dir)
        files.each do |path, content|
          full = File.join(dir, path)
          FileUtils.mkdir_p(File.dirname(full))
          File.write(full, content)
        end
        dir
      end

      # @param profile [String] "docs" or "code"
      # @return [Hash{Symbol => Array}] `{ entities: [names], relations: [[from, type, to]] }`
      def expected(profile)
        EXPECTED.fetch(profile)
      end

      # @param prompt [String] a scan part's prompt
      # @return [Hash] `{ text:, done_reason: }`: the canned items of each file block in the prompt
      def stub_answer(prompt)
        paths = prompt.to_s.scan(/^--- FILE: (\S+)/).flatten.uniq
        project = { "name" => PROJECT_NAME }
        project["description"] = "gadget_engine is a Rails engine for swimmers and their badges." if paths.include?("README.md")
        { text: JSON.generate({ "project" => project, "architecture" => paths.flat_map { |path| ANSWERS.fetch(path, []) } }),
          done_reason: "stop" }
      end

      # @param prompt [String]
      # @return [Boolean] a part of this repo's scan (the fake Ollama routes on it)
      def prompt?(prompt)
        prompt.to_s.include?("(project name: #{PROJECT_NAME})")
      end

      # @return [Manifest::Repo]
      def manifest_repo
        Manifest::Repo.new(key: KEY, url: nil, commit: nil, license: nil, project_name: PROJECT_NAME, full: false,
                           exclude: [], profiles: PROFILES.transform_values(&:dup))
      end

      # @return [Hash{String => String}] relative path => content
      def files
        ns = "module GadgetEngine\n"
        {
          "README.md" => "# gadget_engine\n\nA Rails engine for swimmers and their badges.\n\n- A `Badge` rewards a swimmer's result.\n" \
                         "- `Swimmer` holds a swimmer's details.\n",
          "Gemfile" => %(source "https://rubygems.org"\n\ngemspec\n\ngem "rails"\ngem "grape"\ngem "mysql2"\n),
          "gadget_engine.gemspec" => %(Gem::Specification.new do |spec|\n  spec.name = "gadget_engine"\n  spec.add_dependency "rails"\nend\n),
          "docs/architecture.md" => "# Architecture\n\nSwimmersController lists the swimmers; importers read results files.\n",
          "lib/gadget_engine.rb" => "require \"gadget_engine/engine\"\n\nmodule GadgetEngine\nend\n",
          "lib/gadget_engine/engine.rb" => "#{ns}  class Engine < ::Rails::Engine\n    isolate_namespace GadgetEngine\n  end\nend\n",
          "lib/gadget_engine/version.rb" => "#{ns}  VERSION = \"0.1.0\"\nend\n",
          "app/models/gadget_engine/application_record.rb" =>
            "#{ns}  class ApplicationRecord < ActiveRecord::Base\n    self.abstract_class = true\n  end\nend\n",
          "app/models/gadget_engine/badge.rb" =>
            "#{ns}  # Rewards a swimmer's result.\n  class Badge < ApplicationRecord\n    include Trackable\n    belongs_to :swimmer\n  end\nend\n",
          "app/models/gadget_engine/swimmer.rb" => "#{ns}  class Swimmer < ApplicationRecord\n    has_many :badges\n  end\nend\n",
          "app/models/concerns/gadget_engine/trackable.rb" => "#{ns}  module Trackable\n    extend ActiveSupport::Concern\n  end\nend\n",
          "app/strategies/gadget_engine/importers/badge.rb" =>
            "#{ns}  module Importers\n    # Imports badges from a results file.\n    class Badge\n      def call(file); end\n    end\n  end\nend\n",
          "app/controllers/gadget_engine/application_controller.rb" =>
            "#{ns}  class ApplicationController < ActionController::Base\n  end\nend\n",
          "app/controllers/gadget_engine/swimmers_controller.rb" =>
            "#{ns}  class SwimmersController < ApplicationController\n    def index; end\n\n    def show; end\n  end\nend\n",
          "app/helpers/gadget_engine/swimmers_helper.rb" => "#{ns}  module SwimmersHelper\n  end\nend\n",
          "app/jobs/gadget_engine/render_job.rb" => "#{ns}  class RenderJob < ActiveJob::Base\n    def perform(badge); end\n  end\nend\n",
          "app/mailers/gadget_engine/notice_mailer.rb" => "#{ns}  class NoticeMailer < ActionMailer::Base\n  end\nend\n",
          "app/views/gadget_engine/swimmers/index.html.erb" => "<h1>Swimmers</h1>\n",
          "app/views/gadget_engine/swimmers/show.html.erb" => "<h1>Swimmer</h1>\n",
          "app/views/gadget_engine/notice_mailer/welcome.text.erb" => "Welcome\n",
          "app/views/layouts/gadget_engine/application.html.erb" => "<%= yield %>\n",
          "config/routes.rb" => "GadgetEngine::Engine.routes.draw do\n  resources :swimmers, only: %i[index show]\nend\n"
        }
      end
    end
  end
end
