# frozen_string_literal: true

# Agent-CLI train PR2 (1.68.0, Steve's OK on #152): the folder a project's cloud scans must come
# from, recorded when the operator turns Cloud on (the project's last completed scan), so a scan of
# another folder under an allowed project's name can't pass the gate.
class AddCloudRootToMemoryEntities < ActiveRecord::Migration[8.1]
  def change
    add_column :memory_entities, :cloud_root, :text, null: true
  end
end
