# frozen_string_literal: true

class AddTrustScoreToMemoryObservations < ActiveRecord::Migration[8.0]
  def change
    change_table :memory_observations, bulk: true do |t|
      t.float :trust_score, null: false, default: 0.0
    end

    add_index :memory_observations, :trust_score
  end
end
