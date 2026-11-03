# frozen_string_literal: true

require "rails_helper"

RSpec.describe Llm::Registry do
  after { described_class.reset_overrides! }

  it "fetches the built-in ollama provider and refuses an unknown name" do
    expect(described_class.fetch(:ollama)).to be_a(Llm::OllamaProvider)
    expect(described_class.fetch("ollama")).to be_a(Llm::OllamaProvider)
    expect { described_class.fetch(:agent_cli) }.to raise_error(KeyError)
  end

  it "swaps a provider in until the reset, in the test environment only" do
    fake = Llm::Provider.new
    described_class.override(:ollama, fake)
    expect(described_class.fetch(:ollama)).to equal(fake)

    described_class.reset_overrides!
    expect(described_class.fetch(:ollama)).to be_a(Llm::OllamaProvider)

    allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("production"))
    expect { described_class.override(:ollama, fake) }.to raise_error(RuntimeError, /specs only/)
  end

  it "has a base contract that local providers keep" do
    base = Llm::Provider.new

    expect { base.name }.to raise_error(NotImplementedError)
    expect { base.generate("x", style: "concise") }.to raise_error(NotImplementedError)
    expect(base).to have_attributes(available?: false, cloud?: false, model: nil)
  end
end
