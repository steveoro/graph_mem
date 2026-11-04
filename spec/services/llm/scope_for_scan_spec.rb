# frozen_string_literal: true

require "rails_helper"
require "prism"

# Agent-CLI PR4, step S: a scan's cloud scope comes from the scanned folder (its realpath) and the
# recorded cloud_root, never from the name the caller passes. Temp dirs only.
RSpec.describe "Llm::Scope.for_scan from the folder" do
  around do |example|
    Dir.mktmpdir("llm_scope_scan") do |dir|
      @tmp = File.realpath(dir)
      example.run
    end
  end

  let(:folder) { File.join(@tmp, "Gadget").tap { |path| Dir.mkdir(path) } }
  let!(:gadget) { MemoryEntity.create!(name: "Gadget Project", entity_type: "Project") }
  let!(:alpha) { MemoryEntity.create!(name: "Alpha Project", entity_type: "Project") }

  def scope(root = folder, name = "Gadget Project") = Llm::Scope.for_scan(project_root: root, project_name: name)

  def allowed?(root = folder, name = "Gadget Project") = Llm::CloudGate.allowed?(scope(root, name))

  it "picks the project whose cloud_root is the folder, and lets the scan out" do
    gadget.update!(cloud_allowed: true, cloud_root: folder)

    expect(scope.project_ids).to eq([ gadget.id ])
    expect(scope.scan_root).to eq(folder)
    expect(allowed?).to be(true)
  end

  it "uses the folder, not the name: another project's folder, a name mismatch or a case-only name difference refuses" do
    alpha.update!(cloud_allowed: true, cloud_root: folder)

    expect(scope).to be_unscoped
    expect(allowed?).to be(false)
    expect(scope(folder, "Alpha Project").project_ids).to eq([ alpha.id ])
    expect(allowed?(folder, "alpha project")).to be(false)
    expect(allowed?(folder, nil)).to be(false)
  end

  it "refuses two project roots recorded with the same folder" do
    gadget.update!(cloud_allowed: true, cloud_root: folder)
    alpha.update!(cloud_allowed: true, cloud_root: folder)

    expect(scope).to be_unscoped
    expect(allowed?).to be(false)
  end

  it "refuses a folder that differs from cloud_root only in case (the column's collation would match it)" do
    gadget.update!(cloud_allowed: true, cloud_root: File.join(@tmp, "gadget"))

    expect(allowed?).to be(false)
  end

  it "refuses a project that doesn't allow cloud access, a missing folder, none, and a file" do
    gadget.update!(cloud_root: folder)
    expect(allowed?).to be(false)

    gadget.update!(cloud_allowed: true)
    file = File.join(@tmp, "plain.txt").tap { |path| File.write(path, "Zq7") }
    [ File.join(@tmp, "missing"), nil, "", file ].each { |root| expect(allowed?(root)).to be(false) }
  end

  it "resolves a symlinked or relative folder to its realpath first" do
    gadget.update!(cloud_allowed: true, cloud_root: folder)
    link = File.join(@tmp, "link").tap { |path| File.symlink(folder, path) }

    expect(allowed?(link)).to be(true)
    Dir.chdir(@tmp) { expect(allowed?("Gadget")).to be(true) }
  end

  it "runs no query for a scan that never asks (the Ollama path)" do
    queries = []
    callback = ->(*, payload) { queries << payload[:sql] unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { scope }

    expect(queries).to be_empty
  end

  it "is never called with a positional name by app code (the PR2 form is kept for its specs only)" do
    offenders = Dir.glob(Rails.root.join("{app,lib}/**/*.{rb,rake}")).select do |path|
      calls = []
      visitor = Class.new(Prism::Visitor) do
        define_method(:visit_call_node) do |node|
          calls << node if node.name == :for_scan
          super(node)
        end
      end
      Prism.parse_file(path).value.accept(visitor.new)
      calls.any? { |node| node.arguments&.arguments&.any? { |argument| !argument.is_a?(Prism::KeywordHashNode) } }
    end

    expect(offenders).to be_empty
  end
end
