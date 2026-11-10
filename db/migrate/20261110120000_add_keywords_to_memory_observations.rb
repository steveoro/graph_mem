# frozen_string_literal: true

# Fact pertinence (1.77.0, Steve's plan of 2026-11-10): a fact's keywords, an ordered path of names
# (the project root, the entity that holds the fact, then each project entity it mentions in text
# order), computed deterministically by FactKeywords. Not in `tags`: tags are part of a fact's
# embedded text, so keywords there would change every vector. `keywords_at` is the "computed" stamp
# (NULL = pending), like `embedded_at`.
class AddKeywordsToMemoryObservations < ActiveRecord::Migration[8.1]
  def change
    change_table :memory_observations, bulk: true do |t|
      t.json :keywords, null: false, default: []
      t.datetime :keywords_at, precision: 6, null: true
    end
    # FactKeywordsJob's query is "pending AND active": an obsolete or superseded fact is never
    # computed, so it stays pending; with status in the index the query skips those rows.
    add_index :memory_observations, %i[keywords_at status], name: "idx_memory_observations_keywords_at_status"
  end
end
