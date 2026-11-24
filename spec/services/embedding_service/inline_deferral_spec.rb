# frozen_string_literal: true

require "rails_helper"

# The membership lock is never held across a network call: under it the models' inline embeddings
# are deferred to the outermost lock block's exit (EmbeddingService::InlineDeferral).
RSpec.describe EmbeddingService::InlineDeferral, :with_test_embeddings do
  let!(:calls) { record_embedding_calls! }

  def locked(&) = ProjectMembership.with_membership_lock(&)

  def locked_with_timeout(&) = ProjectMembership.with_membership_lock(timeout: 0, &)

  def create_widget(name = "SynthWidget") = MemoryEntity.create!(name: name, entity_type: "Component")

  it "embeds an entity and an observation created under the lock once the lock is released" do
    entity = nil
    observation = nil
    locked do
      entity = create_widget
      observation = MemoryObservation.create!(memory_entity: entity, content: "SynthWidget renders tiles.")
      expect(calls).to be_empty
    end

    expect(calls.map { |call| call[:text] }).to eq([ "Component: SynthWidget", "SynthWidget renders tiles." ])
    expect(calls).to all(include(held: false, lock_free: true))
    expect([ entity.reload.embedded_at, observation.reload.embedded_at ]).to all(be_present)
  end

  it "re-embeds a text change committed under the lock after the release, with the new text" do
    entity = create_widget
    calls.clear

    locked { ActiveRecord::Base.transaction { entity.update!(aliases: "Tile renderer") } }

    expect(calls.sole).to include(text: "Component: SynthWidget. Aliases: Tile renderer", held: false, lock_free: true)
    expect(entity.reload.embedded_at).to be_present
  end

  it "embeds outside the lock inline, as before" do
    entity = create_widget

    expect(calls.sole).to include(held: false)
    expect(entity.reload.embedded_at).to be_present
  end

  it "embeds once, at the outermost exit, through nested (reentrant) lock blocks" do
    entity = nil
    locked do
      locked do
        entity = create_widget
        locked { entity.update!(description: "Renders tiles.") }
        expect(calls).to be_empty
      end
      expect(calls).to be_empty
    end

    expect(calls.sole).to include(text: "Component: SynthWidget. Renders tiles.", held: false, lock_free: true)
    expect(entity.reload.embedded_at).to be_present
  end

  it "embeds nothing for a create rolled back under the lock" do
    locked do
      ActiveRecord::Base.transaction do
        create_widget
        raise ActiveRecord::Rollback
      end
    end

    expect(calls).to be_empty
    expect(MemoryEntity.where(name: "SynthWidget")).not_to exist
  end

  it "still embeds what committed before an exception, then stops deferring" do
    kept = nil
    expect do
      locked do
        kept = create_widget
        ActiveRecord::Base.transaction do
          create_widget("SynthGear")
          raise "boom"
        end
      end
    end.to raise_error(RuntimeError, "boom")

    expect(calls.sole).to include(text: "Component: SynthWidget", held: false, lock_free: true)
    expect(kept.reload.embedded_at).to be_present
    expect(EmbeddingService.defer_inline_embedding(kept)).to be(false)
    expect(membership_lock_free?).to be(true)
  end

  it "leaves a record whose deferred embedding failed unstamped for the backfill, and embeds the others" do
    allow(EmbeddingService.instance).to receive(:embed_with_retries) { |text, **| deterministic_embedding(text) unless text.include?("SynthWidget") }
    allow(Rails.logger).to receive(:warn).and_call_original
    widget = nil
    gear = nil
    locked do
      widget = create_widget
      gear = create_widget("SynthGear")
    end

    expect(MemoryEntity.missing_embedding).to contain_exactly(widget)
    expect(gear.reload.embedded_at).to be_present

    allow(EmbeddingService).to receive(:embed_entity).and_raise(ActiveRecord::StatementInvalid, "connection lost")
    locked { create_widget("SynthCog") }
    expect(Rails.logger).to have_received(:warn).with(/deferred embedding of MemoryEntity#\d+ failed: connection lost/)
    expect(MemoryEntity.missing_embedding.pluck(:name)).to contain_exactly("SynthWidget", "SynthCog")
  end

  it "doesn't defer another thread's create into this thread's list: that thread embeds it inline" do
    gear = nil
    locked do
      Thread.new { gear = create_widget("SynthGear") }.join
      # The specs' threads share this connection (and its session's lock), so only `held` is per thread.
      expect(calls.map { |call| call.values_at(:text, :held) }).to eq([ [ "Component: SynthGear", false ] ])
    end

    expect(calls.size).to eq(1) # nothing left for this thread's exit
    expect(gear.reload.embedded_at).to be_present
  end

  it "leaves no deferral and no lock depth behind after a LockTimeout" do
    conn = ActiveRecord::Base.connection
    name = ProjectMembership.lock_name(conn)
    # Another session holds the lock (its own pool: this connection would just re-enter it).
    holder = stub_const("DeferralLockHolder", Class.new(ActiveRecord::Base) { self.abstract_class = true })
    holder.establish_connection(ActiveRecord::Base.connection_db_config)
    holder.connection.select_value("SELECT GET_LOCK(#{conn.quote(name)}, 5)")

    expect { locked_with_timeout { create_widget } }.to raise_error(ProjectMembership::LockTimeout)

    expect(ProjectMembership.membership_lock_held?).to be(false)
    expect(ActiveSupport::IsolatedExecutionState[described_class::STATE_KEY]).to be_nil
    gear = create_widget("SynthGear")
    expect(calls.sole).to include(text: "Component: SynthGear", held: false)
    expect(gear.reload.embedded_at).to be_present
    expect(MemoryEntity.where(name: "SynthWidget")).not_to exist
  ensure
    holder.connection.select_value("SELECT RELEASE_LOCK(#{conn.quote(name)})") if holder&.connection
    holder.connection_pool&.disconnect! if holder
  end

  it "defers nothing that is suppressed (the bulk paths enqueue the backfill instead)" do
    entity = locked { EmbeddingService.suppress_inline_embeddings { create_widget } }

    expect(calls).to be_empty
    expect(MemoryEntity.missing_embedding).to contain_exactly(entity)
  end

  it "skips a deferred row that is gone or already embedded when the lock is released" do
    entity = create_widget
    calls.clear
    locked do
      entity.update!(description: "Renders tiles.")
      MemoryEntity.where(id: entity.id).update_all(embedded_at: Time.current)
      create_widget("SynthGear").destroy!
    end

    expect(calls).to be_empty
  end
end
