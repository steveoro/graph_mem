# frozen_string_literal: true

namespace :embeddings do
  desc "Backfill embeddings for all entities and observations missing them"
  task backfill: :environment do
    puts "Backfilling embeddings (model: #{ENV.fetch('EMBEDDING_MODEL', 'nomic-embed-text')})..."
    result = EmbeddingService.backfill_all
    puts "Done. Embedded #{result[:entities]} entities, #{result[:observations]} observations."
  end

  desc "Re-generate all embeddings (clears existing, then backfills)"
  task regenerate: :environment do
    puts "Clearing all existing embeddings..."
    MemoryEntity.update_all(embedding: nil)
    MemoryObservation.update_all(embedding: nil)
    Rake::Task["embeddings:backfill"].invoke
  end

  desc "Add VECTOR INDEX after all embeddings are backfilled (requires MariaDB 11.7+)"
  task add_indexes: :environment do
    conn = ActiveRecord::Base.connection

    unless conn.column_exists?(:memory_entities, :embedding)
      abort "ERROR: embedding columns don't exist. Run migrations first."
    end

    entity_nulls = MemoryEntity.where(embedding: nil).count
    obs_nulls = MemoryObservation.where(embedding: nil).count

    if entity_nulls > 0 || obs_nulls > 0
      abort "ERROR: #{entity_nulls} entities and #{obs_nulls} observations still have NULL embeddings.\n" \
            "Run `bundle exec rake embeddings:backfill` first."
    end

    puts "All rows have embeddings. Converting columns to NOT NULL..."

    conn.execute "ALTER TABLE memory_entities MODIFY embedding VECTOR(768) NOT NULL"
    puts "  ✓ memory_entities.embedding → NOT NULL"

    conn.execute "ALTER TABLE memory_observations MODIFY embedding VECTOR(768) NOT NULL"
    puts "  ✓ memory_observations.embedding → NOT NULL"

    puts "Adding VECTOR INDEX (HNSW, cosine distance)..."

    conn.execute <<~SQL
      ALTER TABLE memory_entities
        ADD VECTOR INDEX idx_memory_entities_embedding (embedding)
        DISTANCE=cosine
    SQL
    puts "  ✓ idx_memory_entities_embedding"

    conn.execute <<~SQL
      ALTER TABLE memory_observations
        ADD VECTOR INDEX idx_memory_observations_embedding (embedding)
        DISTANCE=cosine
    SQL
    puts "  ✓ idx_memory_observations_embedding"

    EmbeddingService.reset_vector_cache!
    puts "Done. VECTOR INDEX active — ANN search enabled."
  end

  desc "Remove VECTOR INDEX and revert columns to nullable"
  task drop_indexes: :environment do
    conn = ActiveRecord::Base.connection

    %w[memory_entities memory_observations].each do |table|
      index_name = "idx_#{table}_embedding"
      result = conn.execute("SHOW INDEX FROM #{table} WHERE Key_name = '#{index_name}'")
      if result.count > 0
        conn.execute("ALTER TABLE #{table} DROP INDEX #{index_name}")
        puts "  ✓ Dropped #{index_name}"
      end

      conn.execute("ALTER TABLE #{table} MODIFY embedding VECTOR(768) DEFAULT NULL")
      puts "  ✓ #{table}.embedding → nullable"
    end

    EmbeddingService.reset_vector_cache!
    puts "Done. VECTOR INDEX removed. Brute-force search still works."
  end
end
