# frozen_string_literal: true

class AddStructuredMetadataToMemories < ActiveRecord::Migration[8.0]
  def change
    change_table :memory_observations, bulk: true do |t|
      t.float :confidence
      t.string :source
      t.datetime :valid_from
      t.datetime :valid_until
      t.json :tags, null: false, default: []
    end

    change_table :memory_relations, bulk: true do |t|
      t.float :weight
      t.float :confidence
      t.json :properties, null: false, default: {}
    end

    add_index :memory_observations, :source
    add_index :memory_observations, :valid_from
    add_index :memory_observations, :valid_until
  end
end
