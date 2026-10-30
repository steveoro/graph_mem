# frozen_string_literal: true

namespace :audit do
  desc "Fill the actor (mcp:graph_*) of change sets and audit rows MCP writes left empty before 1.65.0. Dry run unless APPLY=1"
  task backfill_actors: :environment do
    AuditActorBackfill.new(apply: ENV["APPLY"] == "1").call
  end
end
