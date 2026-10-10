# frozen_string_literal: true

require "rails_helper"
require "tmpdir"
require "json"

RSpec.describe RailsAstExtractor do
  # A small synthetic Rails tree is enough: real apps differ only in scale.
  def build_fixture(dir)
    FileUtils.mkdir_p(File.join(dir, "app/models/admin"))
    FileUtils.mkdir_p(File.join(dir, "app/controllers"))
    FileUtils.mkdir_p(File.join(dir, "config"))

    File.write(File.join(dir, "app/models/swimmer.rb"), <<~RUBY)
      class Swimmer < ApplicationRecord
        belongs_to :team
        has_many :badges
        has_many :meetings, through: :badges
        has_one :user, class_name: "Admin::User"
        scope :by_year, ->(y) { where(year: y) }
        delegate :name, to: :team, prefix: true
      end
    RUBY
    File.write(File.join(dir, "app/models/team.rb"), <<~RUBY)
      class Team < ApplicationRecord
        has_many :swimmers
        has_many :avatars, as: :imageable, polymorphic: false
      end
    RUBY
    File.write(File.join(dir, "app/models/admin/user.rb"), <<~RUBY)
      module Admin
        class User < ApplicationRecord
          belongs_to :swimmer
        end
      end
    RUBY
    File.write(File.join(dir, "app/models/polymorph.rb"), <<~RUBY)
      class Polymorph < ApplicationRecord
        belongs_to :imageable, polymorphic: true
      end
    RUBY
    File.write(File.join(dir, "app/controllers/swimmers_controller.rb"), <<~RUBY)
      class SwimmersController < ApplicationController
        def show; end
        def index; end
      end
    RUBY
    File.write(File.join(dir, "config/routes.rb"), <<~RUBY)
      Rails.application.routes.draw do
        resources :swimmers, only: %i[index show] do
          member { get :stats }
        end
        namespace :admin do
          resources :users
        end
        get 'health', to: 'misc#ping'
      end
    RUBY
  end

  def extract(dir)
    described_class.extract(dir, project_name: "Fixture")
  end

  def edge_labels(result)
    result["links"].reject { |e| e["relation"] == "contains" }.map do |e|
      src = result["nodes"].find { |n| n["id"] == e["source"] }["label"]
      tgt = result["nodes"].find { |n| n["id"] == e["target"] }["label"]
      [ src, e["relation"], tgt, e["confidence"] ]
    end
  end

  it "emits class/file/method nodes with source files and provenance-tagged edges" do
    Dir.mktmpdir do |dir|
      build_fixture(dir)
      result = extract(dir)
      labels = result["nodes"].map { |n| n["label"] }
      expect(labels).to include("Swimmer", "Team", "Admin::User", "swimmer.rb", "Swimmer.by_year")
      rels = result["links"].reject { |e| e["relation"] == "contains" }
      expect(rels).to all(include("properties"))
      expect(rels.map { |e| e.dig("properties", "provenance") }.uniq).to eq([ "RAILS_DSL" ])
      expect(result["producer"]).to eq("rails_ast_extractor")
    end
  end

  it "emits belongs_to/has_many/has_one edges with through+class_name resolution" do
    Dir.mktmpdir do |dir|
      build_fixture(dir)
      edges = edge_labels(extract(dir))
      expect(edges).to include([ "Swimmer", "belongs_to", "Team", "EXTRACTED" ])
      # has_many plural names singularize for the class guess.
      expect(edges).to include([ "Swimmer", "has_many", "Badge", "INFERRED" ])
      expect(edges).to include([ "Team", "has_many", "Swimmer", "EXTRACTED" ])
      expect(edges).to include([ "Swimmer", "has_one", "Admin::User", "EXTRACTED" ])
      expect(edges).to include([ "Admin::User", "belongs_to", "Swimmer", "EXTRACTED" ])
    end
  end

  it "skips polymorphic associations and marks delegates" do
    Dir.mktmpdir do |dir|
      build_fixture(dir)
      edges = edge_labels(extract(dir))
      expect(edges).not_to include([ "Polymorph", "belongs_to", "Imageable", anything ])
      expect(edges).to include([ "Swimmer", "delegates_to", "Team", "EXTRACTED" ])
    end
  end

  it "expands resources into verb Routes with routes_to edges (only:, member:, namespace:)" do
    Dir.mktmpdir do |dir|
      build_fixture(dir)
      result = extract(dir)
      routes = result["nodes"].select { |n| n["entity_type"] == "Route" }.map { |n| n["label"] }
      expect(routes).to include("GET /swimmers", "GET /swimmers/:id",
                                "GET /swimmers/:id/stats", "GET /admin/users",
                                "DELETE /admin/users/:id", "GET /health")
      expect(routes).not_to include("POST /swimmers", "DELETE /swimmers/:id")
      edges = edge_labels(result)
      expect(edges).to include([ "GET /swimmers/:id", "routes_to", "SwimmersController#show", "EXTRACTED" ])
      expect(edges).to include([ "GET /swimmers/:id/stats", "routes_to", "SwimmersController#stats", "EXTRACTED" ])
      expect(edges).to include([ "GET /admin/users", "routes_to", "Admin::UsersController#index", "EXTRACTED" ])
    end
  end

  it "flags AMBIGUOUS when a basename matches constants under two namespaces" do
    Dir.mktmpdir do |dir|
      build_fixture(dir)
      FileUtils.mkdir_p(File.join(dir, "app/models/sales"))
      File.write(File.join(dir, "app/models/sales/user.rb"), <<~RUBY)
        module Sales
          class User < ApplicationRecord; end
        end
      RUBY
      # Swimmer has_many :users — no Swimmer::User or top-level User, but
      # Admin::User AND Sales::User both exist: genuinely undecidable.
      File.write(File.join(dir, "app/models/coach.rb"), <<~RUBY)
        class Coach < ApplicationRecord
          has_many :users
        end
      RUBY
      result = extract(dir)
      amb = result["links"].select { |e| e["confidence"] == "AMBIGUOUS" }
      expect(amb.map { |e| e["relation"] }).to include("has_many")
      coach_edge = amb.find { |e| result["nodes"].find { |n| n["id"] == e["source"] }["label"] == "Coach" }
      expect(coach_edge).not_to be_nil
    end
  end

  it "resolves nested constants lexically (enclosing namespace first)" do
    Dir.mktmpdir do |dir|
      build_fixture(dir)
      File.write(File.join(dir, "app/models/admin/audit.rb"), <<~RUBY)
        module Admin
          class Audit < ApplicationRecord
            belongs_to :user
          end
        end
      RUBY
      result = extract(dir)
      edges = edge_labels(result)
      expect(edges).to include([ "Admin::Audit", "belongs_to", "Admin::User", "EXTRACTED" ])
    end
  end

  it "translates through GraphifyImporter with producer-tagged relation sources" do
    Dir.mktmpdir do |dir|
      build_fixture(dir)
      payload = extract(dir)
      result = GraphifyImporter.new(JSON.generate(payload), project_name: "Fixture").translate
      expect(result.import_data["rescan"]).to eq("rails_ast_extractor")
      rels = result.import_data["relations"]
      expect(rels).not_to be_empty
      expect(rels.map { |r| r.dig("properties", "source") }.uniq).to eq([ "rails_ast_extractor" ])
      expect(result.stats[:relations_emitted]).to be > 5
    end
  end
end
