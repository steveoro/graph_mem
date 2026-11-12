# frozen_string_literal: true

# Fact pertinence F2c (1.83.0): 1–3 words naming what a fact is about, from the LLM
# (FactKeywords::LlmWords), for facts whose keyword path mentions no entity. Never merged with
# `keywords`, never embedded. `llm_keywords_at` is the "computed" stamp (NULL = pending).
class AddLlmKeywordsToMemoryObservations < ActiveRecord::Migration[8.1]
  def change
    change_table :memory_observations, bulk: true do |t|
      t.json :llm_keywords, null: false, default: []
      t.datetime :llm_keywords_at, precision: 6, null: true
    end
    add_index :memory_observations, %i[llm_keywords_at status], name: "idx_memory_observations_llm_keywords_at_status"
  end
end
