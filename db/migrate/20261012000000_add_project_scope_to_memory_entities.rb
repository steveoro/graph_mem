# frozen_string_literal: true

# Project-scoped entity names: `memory_entities.name` was globally unique,
# which made same-name entities from different repos impossible (RepoA's
# `class Foo` vs RepoB's `module Foo` collided at the index) and made
# same-basename File entities across repos collide.
#
# `project_id` records the Project root of the entity's part_of tree (NULL =
# global entity, including every Project root itself and every unclaimed
# reference stub). `project_scope` is a stored generated column — MariaDB
# allows multiple NULLs inside a unique key, so `UNIQUE(project_id, name)`
# alone would let global names duplicate freely; scoping the unique key on
# COALESCE(project_id, 0) keeps global names unique AND frees project-scoped
# names to repeat across projects.
class AddProjectScopeToMemoryEntities < ActiveRecord::Migration[8.1]
  def up
    add_column :memory_entities, :project_id, :bigint, null: true
    add_index :memory_entities, %i[project_id entity_type], name: "idx_memory_entities_project_type"
    # RESTRICT (also the InnoDB default): deleting a Project entity while
    # members still point at it must fail — GraphDeleteService dissolves the
    # project's subtree explicitly before deleting the root.
    add_foreign_key :memory_entities, :memory_entities, column: :project_id, on_delete: :restrict
    execute <<~SQL
      ALTER TABLE memory_entities
        ADD COLUMN project_scope BIGINT GENERATED ALWAYS AS (COALESCE(project_id, 0)) STORED
    SQL
    remove_index :memory_entities, name: "index_memory_entities_on_name"
    add_index :memory_entities, %i[project_scope name], unique: true, name: "index_memory_entities_on_scope_name"
  end

  def down
    # The global UNIQUE(name) can only be restored while no name exists in
    # two scopes. Fail loudly instead of letting the index build fail mid-DDL
    # (or worse, appear to succeed after a manual cleanup nobody reviewed).
    duplicate_names = select_all("SELECT name FROM memory_entities GROUP BY name HAVING COUNT(*) > 1").to_a
    if duplicate_names.any?
      sample = duplicate_names.map { |row| row["name"] }.first(10).join(", ")
      raise ActiveRecord::IrreversibleMigration,
            "Cannot restore global UNIQUE(name): #{duplicate_names.size} names exist in multiple " \
            "projects (#{sample}). Rename, merge, or delete the duplicates first."
    end

    remove_index :memory_entities, name: "index_memory_entities_on_scope_name"
    execute "ALTER TABLE memory_entities DROP COLUMN project_scope"
    remove_foreign_key :memory_entities, column: :project_id
    remove_index :memory_entities, name: "idx_memory_entities_project_type"
    remove_column :memory_entities, :project_id
    add_index :memory_entities, :name, unique: true, name: "index_memory_entities_on_name"
  end
end
