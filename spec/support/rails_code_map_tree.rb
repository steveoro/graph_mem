# frozen_string_literal: true

require "fileutils"

# A synthetic Rails engine ("Gadget") for the Rails code map specs (1.75.0): two classes named Badge
# (a model and an importer strategy), a controller with a views folder, a layout and engine routes,
# a concern, a helper, a job, a mailer with its views, a reserved root module, two non-conventional
# files and a Gemfile plus a gemspec.
module RailsCodeMapTree
  FILES = {
    "Gemfile" => %(source "https://rubygems.org"\n\ngemspec\ngem "rails"\n\ngroup :development do\n  gem "grape"\nend\n),
    "gadget.gemspec" => %(Gem::Specification.new do |spec|\n  spec.name = "gadget"\n  spec.add_dependency "mysql2"\nend\n),
    "README.md" => "# Gadget\n\nA Badge belongs to a Swimmer. The SwimmersController lists swimmers.\n",
    "lib/gadget.rb" => "module Gadget\nend\n",
    "lib/gadget/engine.rb" => "module Gadget\n  class Engine < ::Rails::Engine\n    isolate_namespace Gadget\n  end\nend\n",
    "lib/gadget/version.rb" => "module Gadget\n  VERSION = \"1.0.0\"\nend\n",
    "lib/core_ext/string.rb" => "class String\n  def gadget?\n    true\n  end\nend\n",
    "app/models/gadget/application_record.rb" =>
      "module Gadget\n  class ApplicationRecord < ActiveRecord::Base\n    self.abstract_class = true\n  end\nend\n",
    "app/models/gadget/badge.rb" =>
      "module Gadget\n  class Badge < ApplicationRecord\n    include Gadget::Trackable\n    belongs_to :swimmer\n  end\nend\n",
    "app/models/gadget/swimmer.rb" => "module Gadget\n  class Swimmer < ApplicationRecord\n    has_many :badges\n  end\nend\n",
    "app/models/concerns/gadget/trackable.rb" => "module Gadget\n  module Trackable\n    extend ActiveSupport::Concern\n  end\nend\n",
    "app/strategies/gadget/importers/badge.rb" =>
      "module Gadget\n  module Importers\n    class Badge\n      def call; end\n    end\n  end\nend\n",
    "app/controllers/gadget/application_controller.rb" =>
      "module Gadget\n  class ApplicationController < ActionController::Base\n  end\nend\n",
    "app/controllers/gadget/swimmers_controller.rb" =>
      "module Gadget\n  class SwimmersController < ApplicationController\n    def index; end\n    def show; end\n  end\nend\n",
    "app/helpers/gadget/swimmers_helper.rb" => "module Gadget\n  module SwimmersHelper\n  end\nend\n",
    "app/jobs/gadget/render_job.rb" => "module Gadget\n  class RenderJob < ActiveJob::Base\n  end\nend\n",
    "app/mailers/gadget/notice_mailer.rb" => "module Gadget\n  class NoticeMailer < ActionMailer::Base\n  end\nend\n",
    "app/views/gadget/swimmers/index.html.erb" => "<h1>Swimmers</h1>\n",
    "app/views/gadget/swimmers/show.html.erb" => "<h1>Swimmer</h1>\n",
    "app/views/gadget/notice_mailer/welcome.text.erb" => "Welcome\n",
    "app/views/layouts/gadget/application.html.erb" => "<%= yield %>\n",
    "config/routes.rb" => "Gadget::Engine.routes.draw do\n  resources :swimmers, only: %i[index show]\nend\n"
  }.freeze

  # The code entries the tree maps, name => type.
  CODE_ENTRIES = {
    "Gadget::ApplicationController" => "Controller", "Gadget::ApplicationRecord" => "Model", "Gadget::Badge" => "Model",
    "Gadget::Engine" => "Class", "Gadget::Importers::Badge" => "Strategy", "Gadget::NoticeMailer" => "Mailer",
    "Gadget::RenderJob" => "Job", "Gadget::Swimmer" => "Model", "Gadget::SwimmersController" => "Controller",
    "Gadget::SwimmersHelper" => "Helper", "Gadget::Trackable" => "Concern"
  }.freeze

  # @param dir [String]
  # @param extra [Hash{String => String, nil}] more files (nil removes one of FILES)
  # @return [String] dir
  def write_rails_code_map_tree(dir, extra = {})
    FILES.merge(extra).compact.each do |path, content|
      full = File.join(dir, path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, content)
    end
    dir
  end
end

RSpec.configure do |config|
  config.include RailsCodeMapTree
end
