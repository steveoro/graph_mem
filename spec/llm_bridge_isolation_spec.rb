# frozen_string_literal: true

require "rails_helper"
require "prism"

# Agent-CLI PR3, step T: the host bridge (script/llm_bridge/) stays outside the app (PR4: but for its HTTP client), and
# its files hold no real home path, no IPv4 address but loopback, and no .lan host. Plain text
# checks: no file is run or loaded.
RSpec.describe "LLM host bridge isolation" do
  # 0.0.0.0 only where the bridge says it never binds it, and where the tests show it is refused.
  let(:never_bind) { %w[script/llm_bridge/README.md script/llm_bridge/test/test_bridge.py] }

  def files(pattern)
    Dir.glob(Rails.root.join(pattern), File::FNM_DOTMATCH).select { |path| File.file?(path) && !path.include?("/__pycache__/") }
  end

  def relative(path) = Pathname.new(path).relative_path_from(Rails.root).to_s

  # PR4 wires Rails to the bridge over HTTP: only these files may name it.
  let(:rails_side) do
    %w[app/services/llm/bridge_client.rb app/services/llm/agent_cli_provider.rb app/services/llm/registry.rb app/services/llm/router.rb app/models/app_settings.rb
       app/services/settings_schema.rb app/services/settings_schema/validators.rb config/locales/system_settings.en.yml]
  end

  it "is named under app/, lib/ or config/ only by the Rails side of the bridge (PR4)" do
    named = files("{app,lib,config}/**/*").select { |path| File.binread(path).match?(/llm_bridge|agent_cli|bridge\.token/) }

    expect(named.map { |path| relative(path) }).to match_array(rails_side)
  end

  it "reaches the bridge over HTTP only: nothing under app/, lib/ or config/ reads script/llm_bridge/ or starts a process" do
    # A path to the bridge's files in a string literal (Prism: comments that point at it don't count),
    # or anywhere in a non-Ruby file.
    readers = files("{app,lib,config}/**/*").select do |path|
      next File.binread(path).include?("llm_bridge/") unless path.end_with?(".rb", ".rake")

      strings = []
      visitor = Class.new(Prism::Visitor) do
        define_method(:visit_string_node) do |node|
          strings << node.unescaped
          super(node)
        end
      end
      Prism.parse_file(path).value.accept(visitor.new)
      strings.any? { |text| text.include?("llm_bridge") }
    end
    expect(readers.map { |path| relative(path) }).to be_empty

    spawning = %i[system spawn exec ` fork popen popen2 popen2e popen3 capture2 capture2e capture3 pipeline]
    offenders = (rails_side + %w[app/services/llm/bridge_probe.rb lib/tasks/llm.rake]).select { |path| path.end_with?(".rb", ".rake") }.flat_map do |path|
      calls = []
      visitor = Class.new(Prism::Visitor) do
        define_method(:visit_call_node) do |node|
          calls << node.name if spawning.include?(node.name)
          super(node)
        end
        define_method(:visit_x_string_node) { |_node| calls << :` }
        define_method(:visit_constant_read_node) do |node|
          calls << :Open3 if %i[Open3 PTY].include?(node.name)
          super(node)
        end
      end
      Prism.parse_file(Rails.root.join(path).to_s).value.accept(visitor.new)
      calls.map { |call| "#{path}: #{call}" }
    end
    expect(offenders).to be_empty
  end

  it "has no home-directory path, no IPv4 address but 127.0.0.1, and no .lan host" do
    bridge_files = files("script/llm_bridge/**/*")
    offenders = bridge_files.flat_map do |path|
      text = File.read(path)
      addresses = text.scan(/(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])/).uniq - [ "127.0.0.1" ]
      addresses -= [ "0.0.0.0" ] if never_bind.include?(relative(path))
      hits = addresses.map { |address| "IPv4 #{address}" }
      hits << "home path" if text.match?(%r{/home/[^/\s]+/|/Users/[^/\s]+/|[A-Za-z]:\\+Users\\})
      hits << ".lan host" if text.match?(/\b[\w-]+\.lan\b/i)
      hits.map { |hit| "#{relative(path)}: #{hit}" }
    end

    expect(bridge_files.size).to be > 10
    expect(offenders).to be_empty
    expect(File.readlines(Rails.root.join(never_bind.first)).grep(/0\.0\.0\.0/)).to all(include("never"))
  end
end
