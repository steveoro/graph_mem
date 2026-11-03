# frozen_string_literal: true

require "rails_helper"

# Agent-CLI PR2, step A1: masking a Prompt's data segments and restoring answers exactly.
RSpec.describe Llm::Anonymizer::Session do
  let!(:project) { MemoryEntity.create!(name: "Zq7Canary Project", entity_type: "Project", aliases: "Zq7cp") }
  let!(:widget) { MemoryEntity.create!(name: "Zq7CanaryWidget", entity_type: "Component", project_id: project.id) }
  let!(:service) { MemoryEntity.create!(name: "Zq7 Alpha Service", entity_type: "Service", project_id: project.id, aliases: "Zq7 Alpha") }
  let!(:person) { MemoryEntity.create!(name: "Zq7 Ada", entity_type: "Person", project_id: project.id) }
  let!(:other) { MemoryEntity.create!(name: "Other Zq7 Gizmo", entity_type: "Component") }
  let(:session) { described_class.new(Llm::Scope.for_entities([ widget ])) }

  def prompt(*data) = data.reduce(Llm::Prompt.new.trusted("Notes:\n")) { |memo, text| memo.data(text).trusted("\n") }

  def masked(text) = session.mask(prompt(text)).text.delete_prefix("Notes:\n").delete_suffix("\n")

  it "masks data segments only, with typed tokens, and counts them" do
    result = session.mask(Llm::Prompt.new.trusted("Zq7CanaryWidget [observation_id=7]: ").data("Zq7CanaryWidget talks to Zq7 Ada."))

    expect(result.text).to match(/\AZq7CanaryWidget \[observation_id=7\]: ⟦ENT_\h{4}⟧ talks to ⟦PER_\h{4}⟧\.\z/)
    expect(result.counts).to eq("ENT" => 1, "PER" => 1)
  end

  it "masks every variant, inside identifiers and path segments, longest term first" do
    text = "Zq7Canary Project, zq7canary-project, ZQ7CANARY_PROJECT, Zq7CanaryProjectController, lib/zq7canary_project/x.rb, " \
           "zq7_canary_widget, ZQ7_CANARY_WIDGETS, Zq7 Alpha Service's API, Zq7 Alpha, zq7cp"
    out = masked(text)

    expect(out.downcase.gsub(/[^a-z0-9]/, "")).not_to include("zq7")
    expect(out).to include("⟧Controller", "lib/⟦PRJ_", "⟧/x.rb", "⟧'s API")
    expect(out.scan(/⟦ENT_\h{4}⟧/).size).to eq(4) # two widget forms and both service names
    expect(masked("config/zq7canary.yml and Zq7 Alpha")).to match(%r{\Aconfig/⟦PRJ_\h{4}⟧\.yml and ⟦ENT_\h{4}⟧\z})
  end

  it "keeps project names of other projects masked (PRJ) but not members of other projects" do
    MemoryEntity.create!(name: "Gadget Archive", entity_type: "Project")

    expect(masked("Gadget Archive and Other Zq7 Gizmo")).to match(/\A⟦PRJ_\h{4}⟧ and Other Zq7 Gizmo\z/)
  end

  it "masks a home path's owner everywhere in the prompt" do
    out = session.mask(prompt("ask zq7user", "/home/zq7user/zq7.txt")).text

    expect(out).not_to include("zq7user")
    expect(out).to include("⟦USER_", "⟦PATH_")
  end

  it "round-trips a few hundred generated texts exactly (property)" do
    random = Random.new(7)
    pieces = [ "Zq7Canary Project", "zq7canary-project", "ZQ7CANARY_PROJECT", "Zq7CanaryWidget", "zq7_canary_widget", "Zq7CanaryWidgets",
               "Zq7 Alpha Service's", "zq7cp", "Zq7 Ada", "/srv/zq7/app.rb", "~/zq7/x.md", "/home/zq7user/y", "build.zq7canary.internal",
               "https://git.zq7canary.example/a?b=1", "ops@zq7canary.example", "10.7.7.7", "lib/zq7canary_project/x.rb",
               "plain", "words", "(", ")", ",", ".", "\n", "\"quoted\"", "naïve café", "x = 1;", "Zq7CanaryProjectController#show" ]
    300.times do
      # Word-boundary matching (the plan's): pieces are joined by separators, never fused into one word.
      text = Array.new(random.rand(1..12)) { pieces.sample(random: random) }.join([ " ", "_", "-", "/", ", ", "\n" ].sample(random: random))
      fresh = described_class.new(Llm::Scope.for_entities([ widget ]))
      masked = fresh.mask(Llm::Prompt.new.data(text)).text

      expect(fresh.unmask(masked).text).to eq(text)
      expect(masked).not_to include("Zq7CanaryWidget", "zq7user", "10.7.7.7")
    end
  end

  it "gives the same surface the same token in a session, and other tokens in a new session" do
    first = masked("Zq7CanaryWidget")
    expect(masked("Zq7CanaryWidget again")).to eq("#{first} again")

    other = described_class.new(Llm::Scope.for_entities([ widget ]))
    expect(other.mask(prompt("Zq7CanaryWidget")).text).not_to include(first)
  end

  it "lengthens a clashing suffix to 6, then 8, then refuses" do
    allow(OpenSSL::HMAC).to receive(:hexdigest).and_return("a" * 64)
    tokens = Llm::Anonymizer::Tokens.new

    expect(%w[one two three].map { |surface| tokens.for("ENT", surface) }).to eq(%w[⟦ENT_aaaa⟧ ⟦ENT_aaaaaa⟧ ⟦ENT_aaaaaaaa⟧])
    expect { tokens.for("ENT", "four") }.to raise_error(Llm::Anonymizer::Refused) { |error| expect(error.kind).to eq(:token_clash) }
  end

  {
    "token-like input" => [ :collision, ->(spec) { spec.session.mask(spec.prompt("already ⟦ENT_ab12⟧ here")) } ],
    "a bare token-like word" => [ :collision, ->(spec) { spec.session.mask(spec.prompt("see PRJ_ab12")) } ],
    "a leftover after masking" => [ :leftover, lambda do |spec|
      spec.allow(Llm::Anonymizer::Detectors).to spec.receive(:hit?).and_return(true)
      spec.session.mask(spec.prompt("text"))
    end ],
    "a regex timeout" => [ :timeout, lambda do |spec|
      spec.allow(Llm::Anonymizer::Detectors).to spec.receive(:mask).and_raise(Regexp::TimeoutError)
      spec.session.mask(spec.prompt("text"))
    end ],
    "a dictionary over its cap" => [ :dictionary_cap, lambda do |spec|
      spec.stub_const("Llm::Anonymizer::Dictionary::MAX_TERMS", 3)
      spec.session.mask(spec.prompt("text"))
    end ]
  }.each do |label, (kind, run)|
    it "refuses on #{label}, naming the kind only" do
      expect { run.call(self) }.to raise_error(Llm::Anonymizer::Refused) do |error|
        expect(error.kind).to eq(kind)
        expect(error.message).to eq("anonymizer refused (#{kind})")
      end
    end
  end

  describe "#unmask" do
    let!(:token) { masked("Zq7CanaryWidget") }
    let(:suffix) { token[/_(\h+)⟧/, 1] }

    it "accepts the tolerant forms, keeps a plural as written, and restores ⟦SECRET⟧ as [redacted]" do
      answer = "#{token}, ⟦ ENT_#{suffix} ⟧, [[ENT_#{suffix}]], ENT_#{suffix}, #{token}s, ⟦SECRET⟧, ENT_ffff"

      expect(session.unmask(answer).text).to eq("Zq7CanaryWidget, Zq7CanaryWidget, Zq7CanaryWidget, Zq7CanaryWidget, Zq7CanaryWidgets, [redacted], ENT_ffff")
    end

    it "rejects an invented token and a partial restore" do
      expect { session.unmask("#{token} and ⟦ENT_beef⟧") }.to raise_error(Llm::Anonymizer::RoundTripFailed) { |error| expect(error.kind).to eq(:invented) }
      expect { session.unmask("#{token} and ⟦broken") }.to raise_error(Llm::Anonymizer::RoundTripFailed) { |error| expect(error.kind).to eq(:partial) }
    end

    it "inserts originals JSON-escaped in JSON mode, so the answer still parses" do
      MemoryEntity.create!(name: 'Zq7 "Quoted" \\ Widget', entity_type: "Component", project_id: project.id)
      quoted = masked('Zq7 "Quoted" \\ Widget')

      parsed = JSON.parse(session.unmask({ name: quoted }.to_json, json: true).text)

      expect(parsed).to eq("name" => 'Zq7 "Quoted" \\ Widget')
    end

    it "counts masked terms the answer writes out in plain text" do
      expect(session.unmask("#{token} is not Zq7CanaryWidget").leftovers).to eq(1)
      expect(masked("Zq7CanaryWidget mails Zq7cp") && session.unmask("Zq7cp").leftovers).to eq(1)
      expect(session.unmask("Other Zq7 Gizmo").leftovers).to eq(0)
    end
  end
end
