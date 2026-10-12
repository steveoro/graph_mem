# frozen_string_literal: true

# Adds `memory_observations.perspective` — the world/experience split ported
# from Hindsight (phase C3a). `world` marks external facts (structure of the
# world, code-shape facts); `experience` marks work-log/experience entries
# (what an agent did or learned on the job). NULL stays untyped.
#
# Conservative backfill: only observations stamped by the code-structure
# importers (graphify/rails_ast_extractor) are auto-typed `world` — those
# producers emit factual code observations by construction. Everything else
# keeps NULL; an agent stamps `experience` explicitly on write.
#
# NOTE (design): this is a CLOSED two-value vocabulary — unlike the soft
# `entity_type`/`relation_type` vocabularies (where novel values remain
# valid), `perspective` is validated by hard inclusion because the filter
# semantics are binary. Don't loosen to the DidYouMean suggestion pattern.
class AddPerspectiveToMemoryObservations < ActiveRecord::Migration[8.1]
  def up
    add_column :memory_observations, :perspective, :string, limit: 16
    add_index :memory_observations, :perspective
    execute <<~SQL.squish
      UPDATE memory_observations
         SET perspective = 'world'
       WHERE source IN ('graphify', 'rails_ast_extractor')
    SQL
  end

  def down
    remove_index :memory_observations, :perspective
    remove_column :memory_observations, :perspective
  end
end
