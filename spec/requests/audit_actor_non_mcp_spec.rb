# frozen_string_literal: true

require "rails_helper"

# Audit actor (1.65.0): the web UI and REST keep their server-derived actor and never get a
# claim, even when the source has the "<client>/<model>: <task>" form. Synthetic data only.
RSpec.describe "Audit actor outside MCP", type: :request do
  let!(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component") }

  before { sign_in_operator }

  def latest_audit = AuditLog.where(auditable_type: "MemoryObservation").order(:id).last

  it "records api:<client> for REST, with no claim (the reason still comes from the source)" do
    post api_v1_memory_entity_memory_observations_path(widget),
         params: { memory_observation: { content: "SynthWidget is synthetic.", source: "synth-agent/model-x: synthetic task" } },
         headers: { "X-MCP-Client" => "synth-client-a" }, as: :json

    expect(response).to have_http_status(:created)
    expect(latest_audit).to have_attributes(actor: "api:synth-client-a", actor_claim: nil, reason: "synthetic task")
  end

  it "records operator:<user>@<ip> for the web UI, with no claim" do
    observation = MemoryObservation.create!(memory_entity: widget, content: "SynthWidget renders tiles.")

    post retire_explore_observation_path(observation), params: { reason: "synthetic retire" },
                                                       headers: { "Accept" => "text/vnd.turbo-stream.html" }

    expect(latest_audit).to have_attributes(actor: start_with("operator:"), actor_claim: nil, reason: "synthetic retire")
    expect(ChangeSet.last).to have_attributes(actor: start_with("operator:"), actor_claim: nil)
  end
end
