# frozen_string_literal: true

# Agent-CLI train PR2 (1.68.0): whether a Project root's data, anonymized, may be sent to a cloud
# model. Meaningful on Project roots only; default false. Set only on the Projects page.
class AddCloudAllowedToMemoryEntities < ActiveRecord::Migration[8.1]
  def change
    add_column :memory_entities, :cloud_allowed, :boolean, null: false, default: false
  end
end
