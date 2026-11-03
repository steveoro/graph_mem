# frozen_string_literal: true

require "rails_helper"
require "prism"

# Agent-CLI train PR1, step T: static checks over the Ruby files of app/ and lib/ (parsed with
# Prism, so strings and comments never match; a file that doesn't parse fails the spec). Every
# model call goes through Llm::Router, so only the Ollama provider reaches SummaryGenerationClient;
# and app code never starts a process. Views (.haml, .erb) are out of scope here: at runtime
# SubprocessGuard (spec/support/llm.rb, the same lib/tasks/db_utils.rake exemption) catches a
# process started from any file under app/, views included.
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

  # Finds `Receiver.method` calls (a literal `send(:x)` / `public_send` / `__send__` / `method(:x)`
  # counts as a call of x), constant references, backticks and %x() in one file.
  let(:visitor_class) do
    Class.new(Prism::Visitor) do
      attr_reader :calls, :constants, :backticks

      def initialize
        super
        @calls = []
        @constants = []
        @backticks = []
      end

      def visit_call_node(node)
        receiver = node.receiver
        name = case receiver
        when nil then nil
        when Prism::ConstantReadNode, Prism::ConstantPathNode then constant_name(receiver)
        else :other
        end
        @calls << [ name, target(node), node.location.start_line ] unless name == :other
        super
      end

      def visit_constant_read_node(node)
        @constants << node.name.to_s
        super
      end

      def visit_constant_path_node(node)
        @constants << constant_name(node)
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

      private

      # "::Process" and "Process" are the same receiver.
      def constant_name(node)
        node.is_a?(Prism::ConstantReadNode) ? node.name.to_s : node.full_name.delete_prefix("::")
      rescue Prism::ConstantPathNode::DynamicPartsInConstantPathError
        node.name.to_s
      end

      def target(node)
        first = node.arguments&.arguments&.first
        %i[send public_send __send__ method].include?(node.name) && first.is_a?(Prism::SymbolNode) ? first.unescaped.to_sym : node.name
      end
    end
  end

  # @return [Array(String, Object)] each file's repo-relative path and its visitor
  def sources(*dirs)
    dirs.flat_map { |dir| Dir.glob(Rails.root.join(dir, "**/*.{rb,rake}")) }.sort.map do |path|
      [ Pathname.new(path).relative_path_from(Rails.root).to_s, scan(path) ]
    end
  end

  def scan(path)
    result = Prism.parse_file(path)
    raise "#{path} doesn't parse: #{result.errors.map(&:message).join('; ')}" unless result.success?

    visitor_class.new.tap { |visitor| result.value.accept(visitor) }
  end

  it "calls SummaryGenerationClient.generate only from Llm::OllamaProvider, and names the client in two other files only" do
    files = sources("app", "lib")
    callers = files.filter_map do |path, visitor|
      path if visitor.calls.any? { |receiver, name, _| receiver == "SummaryGenerationClient" && %i[generate instance new].include?(name) }
    end
    # Any reference counts, so a client held in a variable and called later (`client: SummaryGenerationClient`) is caught.
    references = files.filter_map do |path, visitor|
      path if visitor.constants.any? { |name| name == "SummaryGenerationClient" || name.start_with?("SummaryGenerationClient::") }
    end

    expect(callers).to eq([ "app/services/llm/ollama_provider.rb" ])
    expect(references).to eq([ "app/controllers/concerns/settings_group_update.rb", # reset_instance! on a settings save
                               "app/services/llm/ollama_provider.rb", "app/services/summary_generation_client.rb" ])
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

  it "would see a backtick, ::Process, a literal send, a held client and a bare system call (the scan works)" do
    Dir.mktmpdir("llm_architecture") do |dir|
      path = File.join(dir, "synth_widget_runner.rb")
      File.write(path, <<~RUBY)
        x = `ls`
        Open3.capture2("ls")
        system("ls")
        # system("in a comment")
        puts 'system("in a string")'
        ::Process.spawn("ls")
        Kernel.send(:system, "ls")
        client = SummaryGenerationClient
      RUBY
      visitor = scan(path)

      expect(visitor.backticks).to eq([ 1 ])
      expect(visitor.calls.select { |receiver, name, _| process_calls.fetch(receiver, []).include?(name) })
        .to eq([ [ "Open3", :capture2, 2 ], [ nil, :system, 3 ], [ "Process", :spawn, 6 ], [ "Kernel", :system, 7 ] ])
      expect(visitor.constants).to include("SummaryGenerationClient")

      File.write(path, "def broken(\n")
      expect { scan(path) }.to raise_error(RuntimeError, /doesn't parse/)
    end
  end
end
