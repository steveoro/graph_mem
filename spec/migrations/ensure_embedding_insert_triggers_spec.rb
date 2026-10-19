# frozen_string_literal: true

require "rails_helper"
load Rails.root.join("db/migrate/20261019120000_ensure_embedding_insert_triggers.rb")

RSpec.describe EnsureEmbeddingInsertTriggers do
  it "delegates trigger installation to the convergent manager" do
    allow(EmbeddingVectorTriggerManager).to receive(:install!)
      .and_return(installed: [], unchanged: [], skipped: [])

    described_class.new.up

    expect(EmbeddingVectorTriggerManager).to have_received(:install!)
  end
end
