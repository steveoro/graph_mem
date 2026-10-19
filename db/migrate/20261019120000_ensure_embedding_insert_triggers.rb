# frozen_string_literal: true

# Repairs databases where AddEmbeddingInsertTriggers ran while the embedding
# columns were still nullable — e.g. a different migrate order or a schema
# loaded before the triggers existed: such DBs end up indexed but triggerless,
# which StructureDumpGuard flags on every db:schema:dump.
#
# EmbeddingVectorTriggerManager.install! is convergent: it (re)creates only
# missing or drifted triggers, no-ops on healthy DBs, and skips tables whose
# embedding column is still nullable (those converge via
# `embeddings:add_indexes` once backfill is done).
class EnsureEmbeddingInsertTriggers < ActiveRecord::Migration[8.1]
  def up
    report = EmbeddingVectorTriggerManager.install!
    say "triggers installed: #{report[:installed].join(', ').presence || 'none'}"
    say "triggers already correct: #{report[:unchanged].join(', ')}" if report[:unchanged].any?
    report[:skipped].each { |reason| say "skipped: #{reason}" }
  end

  def down
    # Trigger presence is convergent state owned by install! and
    # embeddings:drop_indexes — rolling this back has nothing to undo.
  end
end
