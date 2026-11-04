# frozen_string_literal: true

require "rails_helper"
require "prism"

# Agent-CLI PR5, step T: every provider with cloud? true is reached only through Llm::CloudCall (gate,
# budget, mask, restore), on every route: the primary model, a backup model and the JSON retry.
# Static checks over app/ and lib/ plus a runtime check of the call stack of each cloud generate.
RSpec.describe "Cloud providers only through CloudCall" do
  let!(:project) { MemoryEntity.create!(name: "Gadget Project", entity_type: "Project", cloud_allowed: true) }
  let!(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component", project_id: project.id) }

  def calls_in(path)
    found = []
    visitor = Class.new(Prism::Visitor) do
      define_method(:visit_call_node) do |node|
        receiver = node.receiver
        found << [ receiver.is_a?(Prism::ConstantReadNode) || receiver.is_a?(Prism::ConstantPathNode) ? receiver.slice : nil, node.name ]
        super(node)
      end
    end
    Prism.parse_file(path).value.accept(visitor.new)
    found
  end

  def files_calling(receiver, name)
    Dir.glob(Rails.root.join("{app,lib}/**/*.{rb,rake}")).select { |path| calls_in(path).include?([ receiver, name ]) }
                                                     .map { |path| Pathname.new(path).relative_path_from(Rails.root).to_s }
  end

  it "fetches providers only in the Router's chain walk, and builds CloudCall only there" do
    expect(files_calling("Registry", :fetch)).to contain_exactly("app/services/llm/router.rb", "app/services/llm/chain_run.rb")
    expect(files_calling("CloudCall", :new)).to eq([ "app/services/llm/chain_run.rb" ])
    expect(files_calling("Llm::AgentCliProvider", :new) + files_calling("AgentCliProvider", :new)).to be_empty
  end

  it "calls every cloud generate from inside CloudCall: primary, backup model and JSON retry" do
    AppSettings.clear_cache
    AppSettings.llm_profile_claude_model = "zq7-claude"
    AppSettings.llm_profile_claude_backup_models = "zq7-claude-b1"
    AppSettings.llm_chain_scan = "claude,ollama"
    answers = [ [ 200, { ok: false, failure_class: "cli_quota" } ], [ 200, { ok: true, text: "[1]" } ], [ 200, { ok: true, text: '{"architecture": []}' } ] ]
    stub = start_bridge_stub { answers.shift }
    stacks = []
    allow_any_instance_of(Llm::AgentCliProvider).to receive(:generate).and_wrap_original do |original, *args, **kwargs| # rubocop:disable RSpec/AnyInstance
      stacks << caller_locations.map(&:path)
      original.call(*args, **kwargs)
    end
    prompt = Llm::Prompt.new.trusted("Extract:\n").data("SynthWidget renders frames.").scoped(Llm::Scope.for_entities([ widget ]))

    result = with_llm_provider(FakeProvider.new(name: "ollama")) { Llm::Router.generate(:scan, prompt, style: "concise", options: { format: "json" }) }

    expect(result).to include(ok: true, provider: "agent_cli")
    expect(stub.requests.map { |request| request.json["model"] }).to eq(%w[zq7-claude zq7-claude-b1 zq7-claude-b1])
    expect(stacks.size).to eq(3)
    expect(stacks).to all(include(end_with("app/services/llm/cloud_call.rb")))
  ensure
    AppSettings.clear_cache
  end

  it "sends a cloud provider registered under any name through CloudCall too" do
    stacks = []
    cloudy = FakeProvider.new(cloud: true) do |*|
      stacks << caller_locations.map(&:path)
      { ok: true, text: "done", error: nil, latency_ms: 1.0 }
    end
    project.update!(cloud_allowed: true)
    prompt = Llm::Prompt.new.data("SynthWidget").scoped(Llm::Scope.for_entities([ widget ]))

    with_llm_provider(cloudy) { Llm::Router.generate(:judge, prompt, style: "concise") }

    expect(stacks.sole).to include(end_with("app/services/llm/cloud_call.rb"))
  end
end
