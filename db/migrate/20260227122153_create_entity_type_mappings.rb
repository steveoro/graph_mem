# frozen_string_literal: true

class CreateEntityTypeMappings < ActiveRecord::Migration[8.0]
  def change
    create_table :entity_type_mappings, charset: "utf8mb4", collation: "utf8mb4_general_ci" do |t|
      t.string :canonical_type, null: false
      t.string :variant, null: false

      t.timestamps
    end

    add_index :entity_type_mappings, :canonical_type
    add_index :entity_type_mappings, :variant, unique: true
  end
end
