# frozen_string_literal: true

require "rails_helper"

# Audit actor (1.65.0): the claim is self-reported text, parsed strictly and sanitized.
RSpec.describe ActorClaim do
  describe ".source_parts" do
    {
      "claude-code/opus: fact supersede review" => [ "claude-code/opus", "fact supersede review" ],
      "synth-agent/model-x: synthetic task" => [ "synth-agent/model-x", "synthetic task" ],
      "cursor/gpt-5.1@work: a task: with a colon" => [ "cursor/gpt-5.1@work", "a task: with a colon" ],
      "  synth-agent/model-x:   padded  " => [ "synth-agent/model-x", "padded" ],
      "docs:README.md" => nil,
      "project_scan:12:reconcile" => nil,
      "operator" => nil,
      "" => nil,
      nil => nil,
      "synth-agent: no slash" => nil,
      "synth-agent/model-x:" => nil,
      "synth-agent/model-x: first line\nsecond line" => nil,
      "synth agent/model: space in who" => nil
    }.each do |source, parts|
      it "reads #{source.inspect} as #{parts.inspect}" do
        expect(described_class.source_parts(source)).to eq(parts)
      end
    end

    it "strips control characters and truncates the why" do
      expect(described_class.source_parts("synth-agent/model-x: a\u0007b\tc")).to eq([ "synth-agent/model-x", "a b c" ])
      expect(described_class.source_parts("synth-agent/model-x: #{'w' * 300}").last.length).to eq(255)
    end
  end

  describe ".transport" do
    it "joins the client id and the clientInfo, leaving out the default client and blanks" do
      expect(described_class.transport(client_id: "synth-client-a", client_info: { name: "synth-agent", version: "0.0.1" }))
        .to eq("client=synth-client-a · synth-agent/0.0.1")
      expect(described_class.transport(client_id: "default", client_info: { "name" => "synth-agent" })).to eq("synth-agent")
      expect(described_class.transport(client_id: nil, client_info: "synth-agent")).to be_nil
      expect(described_class.transport(client_id: "synth-client-a", client_info: { version: "1" })).to eq("client=synth-client-a")
    end
  end

  it "joins sanitized parts and truncates the whole value to 255" do
    expect(described_class.join("a\nb", nil, " ", "c")).to eq("a b · c")
    expect(described_class.join(nil, "")).to be_nil
    expect(described_class.join("x" * 200, "y" * 200).length).to eq(255)
  end
end
