# frozen_string_literal: true

require "rails_helper"
require "prism"

# Agent-CLI train PR1, step T: static checks over app/ and lib/ (parsed with Prism, so strings
# and comments never match). Every model call goes through Llm::Router, so only the Ollama
# provider reaches SummaryGenerationClient; and app code never starts a process (the runtime
# side is SubprocessGuard in spec/support/llm.rb, with the same lib/tasks/db_utils.rake exemption).
RSpec.describe "LLM architecture" do
  # Calls that start a process, by receiver (nil = an implicit Kernel call).
  let(:process_calls) do
    {
      nil => %i[system spawn exec fork open],
      "Kernel" => %i[system spawn exec fork open],
      "Process" => %i[spawn exec fork],
      "IO" => %i[popen],
      "PTY" => %i[spawn getpty],
      "Open3" => SubprocessGuard::OPEN3_METHODS
    }
  end

  # Finds `Receiver.method` calls, backticks and %x() in one file.
  let(:visitor_class) do
    Class.new(Prism::Visitor) do
      attr_reader :calls, :backticks

      def initialize
        super
        @calls = []
        @backticks = []
      end

      def visit_call_node(node)
        receiver = node.receiver
        name = case receiver
        when nil then nil
        when Prism::ConstantReadNode then receiver.name.to_s
        when Prism::ConstantPathNode then receiver.full_name
        else :other
        end
        @calls << [ name, node.name, node.location.start_line ] unless name == :other
        super
      end

      def visit_x_string_node(node)
        @backticks << node.location.start_line
        super
      end

      def visit_interpolated_x_string_node(node)
        @backticks << node.location.start_line
        super
      end
    end
  end

  def sources(*dirs)
    dirs.flat_map { |dir| Dir.glob(Rails.root.join(dir, "**/*.{rb,rake}")) }.sort.map do |path|
      visitor = visitor_class.new
      Prism.parse_file(path).value.accept(visitor)
      [ Pathname.new(path).relative_path_from(Rails.root).to_s, visitor ]
    end
  end

  it "calls SummaryGenerationClient.generate only from Llm::OllamaProvider" do
    callers = sources("app", "lib").filter_map do |path, visitor|
      path if visitor.calls.any? { |receiver, name, _| receiver == "SummaryGenerationClient" && %i[generate instance new].include?(name) }
    end

    expect(callers).to eq([ "app/services/llm/ollama_provider.rb" ])
  end

  it "starts no process from app/ or lib/ (lib/tasks/db_utils.rake excepted)" do
    found = sources("app", "lib").flat_map do |path, visitor|
      next [] if SubprocessGuard::EXEMPT_PATHS.include?(path)

      hits = visitor.calls.select { |receiver, name, _| process_calls.fetch(receiver, []).include?(name) }
      hits.map { |receiver, name, line| "#{path}:#{line} #{[ receiver, name ].compact.join('.')}" } +
        visitor.backticks.map { |line| "#{path}:#{line} backtick" }
    end

    expect(found).to be_empty
  end

  it "would see a backtick, Open3 and a bare system call (the scan works)" do
    Dir.mktmpdir("llm_architecture") do |dir|
      path = File.join(dir, "synth_widget_runner.rb")
      File.write(path, "x = `ls`\nOpen3.capture2('ls')\nsystem('ls')\n# system('in a comment')\nputs 'system(\"in a string\")'\n")
      visitor = visitor_class.new
      Prism.parse_file(path).value.accept(visitor)

      expect(visitor.backticks).to eq([ 1 ])
      expect(visitor.calls.select { |receiver, name, _| process_calls.fetch(receiver, []).include?(name) })
        .to eq([ [ "Open3", :capture2, 2 ], [ nil, :system, 3 ] ])
    end
  end
end
