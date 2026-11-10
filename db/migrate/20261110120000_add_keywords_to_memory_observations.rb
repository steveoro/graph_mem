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
    add_index :memory_observations, :keywords_at, name: "idx_memory_observations_keywords_at"
  end
end
