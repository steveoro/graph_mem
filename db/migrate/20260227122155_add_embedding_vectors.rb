# frozen_string_literal: true

# Adds VECTOR(768) columns for semantic embedding search.
# Requires MariaDB 11.7+ for native VECTOR support.
# Skips gracefully on older versions -- vector search will be unavailable
# but all other functionality works normally.
#
# After running this migration on MariaDB 11.7+, backfill embeddings with:
#   bundle exec rake embeddings:backfill
class AddEmbeddingVectors < ActiveRecord::Migration[8.0]
  def up
    if vector_supported?
      execute "ALTER TABLE memory_entities ADD COLUMN embedding VECTOR(768) DEFAULT NULL"
      execute "ALTER TABLE memory_observations ADD COLUMN embedding VECTOR(768) DEFAULT NULL"
    else
      say "Skipping VECTOR columns: MariaDB #{mariadb_version} does not support VECTOR (requires 11.7+)"
    end
  end

  def down
    remove_column :memory_entities, :embedding if column_exists?(:memory_entities, :embedding)
    remove_column :memory_observations, :embedding if column_exists?(:memory_observations, :embedding)
  end

  private

  def vector_supported?
    version = mariadb_version
    return false unless version

    major, minor = version.split(".").map(&:to_i)
    major > 11 || (major == 11 && minor >= 7)
  end

  def mariadb_version
    result = execute("SELECT VERSION()").first
    version_string = result.is_a?(Array) ? result[0] : result.values.first
    match = version_string.to_s.match(/(\d+\.\d+\.\d+)/)
    match ? match[1] : nil
  rescue StandardError
    nil
  end
end
