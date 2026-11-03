# frozen_string_literal: true

require "rails_helper"
require "prism"

# Agent-CLI PR2, step T: static checks over app/ and lib/ (Prism for Ruby, so comments and strings
# never match), and the anonymizer's speed on a large scan part.
RSpec.describe "LLM cloud architecture" do
  # Every call (receiver constant name or nil, method name) and every constant named, per file.
  let(:visitor_class) do
    Class.new(Prism::Visitor) do
      attr_reader :calls, :constants

      def initialize
        super
        @calls = []
        @constants = []
      end

      def visit_call_node(node)
        receiver = node.receiver
        @calls << [ receiver.is_a?(Prism::ConstantReadNode) ? receiver.name.to_s : receiver&.type, node.name ]
        super
      end

      def visit_constant_read_node(node)
        @constants << node.name.to_s
        super
      end
    end
  end

  def ruby_files(*dirs) = dirs.flat_map { |dir| Dir.glob(Rails.root.join(dir, "**/*.{rb,rake}")) }.sort

  def scan(path)
    result = Prism.parse_file(path)
    raise "#{path} doesn't parse" unless result.success?

    visitor_class.new.tap { |visitor| result.value.accept(visitor) }
  end

  def relative(path) = Pathname.new(path).relative_path_from(Rails.root).to_s

  it "names Llm::Anonymizer only inside app/services/llm/" do
    users = ruby_files("app", "lib").select { |path| scan(path).constants.include?("Anonymizer") }.map { |path| relative(path) }

    expect(users).to all(start_with("app/services/llm/"))
    expect(users).to include("app/services/llm/cloud_call.rb", "app/services/llm/scope.rb")
  end

  it "masks and unmasks only in Llm::CloudCall" do
    callers = ruby_files("app", "lib").select do |path|
      scan(path).calls.any? { |receiver, name, *| %i[mask unmask].include?(name) && receiver != "Detectors" }
    end

    expect(callers.map { |path| relative(path) }).to eq([ "app/services/llm/cloud_call.rb" ])
  end

  it "writes no log, file or output from the anonymizer" do
    offenders = ruby_files("app/services/llm/anonymizer").flat_map do |path|
      visitor = scan(path)
      hits = visitor.constants & %w[File IO Dir Logger STDOUT STDERR]
      hits += visitor.calls.select { |receiver, name| name == :logger || (receiver.nil? && %i[puts print p pp warn].include?(name)) }.map(&:last)
      hits.map { |hit| "#{relative(path)}: #{hit}" }
    end

    expect(offenders).to be_empty
  end

  it "keeps cloud_allowed to the migration, the model, the Projects page and the gate" do
    files = Dir.glob(Rails.root.join("{app,lib,config,db/migrate}/**/*.{rb,rake,haml,erb,yml}")).select { |path| File.read(path).include?("cloud_allowed") }

    expect(files.map { |path| relative(path) }).to contain_exactly(
      "app/models/memory_entity.rb", "app/controllers/projects/cloud_access_controller.rb", "app/services/llm/cloud_gate.rb",
      "app/views/projects/index.html.haml", "db/migrate/20261103140000_add_cloud_allowed_to_memory_entities.rb"
    )
  end

  it "masks a 200 KB scan part against 10,000 terms in well under the bound" do
    dictionary = Llm::Anonymizer::Dictionary.new
    10_000.times { |i| dictionary.add("ENT", "Zq7Widget#{i}") }
    allow(Llm::Anonymizer::Dictionary).to receive(:build).and_return(dictionary)
    line = "class Zq7Widget42Controller < Base # see /srv/zq7/app.rb and ops@zq7.example, zq7_widget_9001 plain words\n"
    text = line * (200_000 / line.length)
    session = Llm::Anonymizer::Session.new(Llm::Scope.for_entities([]))

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    masked = session.mask(Llm::Prompt.new.data(text))
    seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    expect(seconds).to be < 3.0
    expect(masked.text).not_to include("Zq7Widget42", "zq7_widget_9001", "ops@zq7.example")
    expect(session.unmask(masked.text).text).to eq(text)
  end
end
