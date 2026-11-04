# frozen_string_literal: true

require "rails_helper"

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
    %w[app/services/llm/bridge_client.rb]
  end

  it "is named under app/, lib/ or config/ only by the Rails side of the bridge (PR4)" do
    named = files("{app,lib,config}/**/*").select { |path| File.binread(path).match?(/llm_bridge|agent_cli|bridge\.token/) }

    expect(named.map { |path| relative(path) }).to match_array(rails_side)
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
