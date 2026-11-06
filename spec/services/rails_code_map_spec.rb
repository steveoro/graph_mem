# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

# 1.75.0: the deterministic Rails code map of a synthetic engine (spec/support/rails_code_map_tree.rb).
RSpec.describe RailsCodeMap do
  def build(extra = {}, **options)
    Dir.mktmpdir("code-map") do |dir|
      write_rails_code_map_tree(dir, extra)
      yield described_class.build(dir, reserved_names: [ "Gadget" ], **options)
    end
  end

  it "maps each file's main constant with its role type, aliases and Defined at fact" do
    build do |map|
      code = map.entries.reject { |entry| %w[View Layout Route].include?(entry.type) }

      expect(code.to_h { |entry| [ entry.name, entry.type ] }).to eq(RailsCodeMapTree::CODE_ENTRIES)
      badge = map.entry("Gadget::Badge")
      expect(badge.aliases).to eq([ "Badge", "gadget/badge" ])
      expect(badge.files).to eq([ "app/models/gadget/badge.rb" ])
      expect(badge.facts).to eq([ "Defined at app/models/gadget/badge.rb:L2" ])
      expect(badge.superclass).to eq("ApplicationRecord")
      expect(map.entry("Gadget::Trackable").aliases).to eq([ "Trackable", "gadget/trackable" ])
    end
  end

  it "skips the reserved root module and counts the non-conventional files" do
    build do |map|
      expect(map.entry("Gadget")).to be_nil
      expect(map.counters).to include(reserved: 1, non_conventional_files: 2, unreadable_files: 0, complete: true)
    end
  end

  it "maps view folders and layouts by path, and the routes file" do
    build do |map|
      expect(map.entry("app/views/gadget/swimmers")).to have_attributes(type: "View",
                                                                        facts: [ "Templates: index.html.erb, show.html.erb" ])
      expect(map.entry("app/views/gadget/notice_mailer").type).to eq("View")
      expect(map.entry("app/views/layouts/gadget/application.html.erb"))
        .to have_attributes(type: "Layout", facts: [ "Defined at app/views/layouts/gadget/application.html.erb" ])
      expect(map.entry("config/routes.rb").type).to eq("Route")
      expect(map.counters).to include(entities: 15, views: 3)
    end
  end

  it "relates entries by code edges, engine routes and views, never to a constant outside the map" do
    build do |map|
      edges = map.edges.map { |edge| [ edge.from, edge.relation, edge.to ] }

      expect(edges).to include([ "Gadget::Badge", "belongs_to", "Gadget::Swimmer" ], [ "Gadget::Swimmer", "has_many", "Gadget::Badge" ],
                               [ "Gadget::Badge", "mixes_in", "Gadget::Trackable" ],
                               [ "Gadget::Badge", "inherits", "Gadget::ApplicationRecord" ],
                               [ "config/routes.rb", "routes_to", "Gadget::SwimmersController" ],
                               [ "Gadget::SwimmersController", "relates_to", "app/views/gadget/swimmers" ],
                               [ "Gadget::NoticeMailer", "relates_to", "app/views/gadget/notice_mailer" ],
                               [ "Gadget::ApplicationController", "relates_to", "app/views/layouts/gadget/application.html.erb" ])
      expect(edges.flat_map { |from, _, to| [ from, to ] }).to all(satisfy { |name| map.entry(name) })
      expect(map.entry("Gadget::SwimmersController").facts).to include("Routes: GET /swimmers, GET /swimmers/:id")
    end
  end

  it "reads the declared gems from the Gemfile and the gemspec" do
    build do |map|
      expect(map.gems).to include("rails", "grape", "mysql2")
      expect(map.gem?("Grape")).to be(true)
      expect(map.gem?("Swimmer")).to be(false)
    end
  end

  it "keeps a file the scan's filter refuses out of the map" do
    build({}, keep: ->(path) { !path.end_with?("render_job.rb") }) do |map|
      expect(map.entry("Gadget::RenderJob")).to be_nil
    end
  end

  it "is empty for a folder that isn't a Rails project" do
    Dir.mktmpdir("code-map") do |dir|
      File.write(File.join(dir, "Gemfile"), %(gem "rack"\n))
      FileUtils.mkdir_p(File.join(dir, "lib"))
      File.write(File.join(dir, "lib/widget.rb"), "class Widget\nend\n")

      expect(described_class.build(dir)).to be(described_class::Map::EMPTY)
    end
  end

  it "marks the map incomplete past its file cap" do
    stub_const("#{described_class}::MAX_FILES", 3)
    build({ "app/models/gadget/broken.rb" => "class Broken <\n" }) do |map|
      expect(map.complete?).to be(false)
      expect(map.counters[:complete]).to be(false)
    end
  end

  it "lists an unparsable file as unreadable" do
    build({ "app/models/gadget/broken.rb" => "class Broken <\n" }) do |map|
      expect(map.unreadable_files).to eq([ "app/models/gadget/broken.rb" ])
      expect(map.counters[:unreadable_files]).to eq(1)
    end
  end
end
