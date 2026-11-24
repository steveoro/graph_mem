# frozen_string_literal: true

require "rails_helper"

# The guard in spec/support/embedding_lock_guard.rb: no embedding call while this thread holds the
# membership lock.
RSpec.describe EmbeddingLockGuard do
  let(:entity) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component") }

  it "refuses the real client's call under the lock, vectors off, and names the caller and the fix" do
    entity
    expect { ProjectMembership.with_membership_lock { EmbeddingService.embed_entity(entity) } }
      .to raise_error(described_class::Violation, /EmbeddingService#embed_entity called under the membership lock from spec\/embedding_lock_guard_spec\.rb:\d+.*deferred to the outermost lock's exit/)

    # The after hook would fail this example on the recorded attempt; clear it here.
    expect(described_class.drain!.sole).to start_with("EmbeddingService#embed_entity called under the membership lock")
  end

  it "refuses the :with_test_embeddings stub's call under the lock", :with_test_embeddings do
    expect { ProjectMembership.with_membership_lock { EmbeddingService.embed("SynthWidget renders tiles.") } }
      .to raise_error(described_class::Violation, /EmbeddingService#embed called/)
    expect(described_class.drain!.size).to eq(1)
  end

  it "records a call that a model callback swallows (an inline embedding no longer deferred)" do
    allow(EmbeddingService).to receive(:defer_inline_embedding).and_return(false)

    ProjectMembership.with_membership_lock { entity }

    expect(described_class.drain!.sole).to start_with("EmbeddingService#embed_entity called under the membership lock")
  end

  it "lets calls outside the lock through, also right after a lock block" do
    ProjectMembership.with_membership_lock { :done }
    EmbeddingService.embed_entity(entity)

    expect(described_class.drain!).to be_empty
  end
end
