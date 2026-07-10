# frozen_string_literal: true

namespace :embeddings do
  desc "Smoke-test the embedding endpoint"
  task check: :environment do
    config = EmbeddingConfig.resolved_config

    puts "Provider : #{config[:provider]}"
    puts "URL      : #{config[:url]}"
    puts "Model    : #{config[:model]}"
    puts "Dims     : #{config[:dims]}"
    puts

    svc = EmbeddingService.new
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    vec = svc.embed!("connection test")
    elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round(1)

    puts "OK: got #{vec.length}-dim vector in #{elapsed} ms"
    puts "    first 5: [#{vec.first(5).map { |v| v.round(6) }.join(', ')}]"

    if vec.length != config[:dims]
      puts "WARN: expected #{config[:dims]} dims, got #{vec.length} — check embedding dimensions config"
    end
  rescue StandardError => e
    abort "FAIL: #{e.class}: #{e.message}"
  end

  desc "Backfill embeddings for all entities and observations missing them"
  task backfill: :environment do
    model = EmbeddingConfig.resolved_config[:model]
    puts "Backfilling embeddings (model: #{model})..."
    result = EmbeddingService.backfill_all
    puts "Done. Embedded #{result[:entities]} entities, #{result[:observations]} observations."
  end

  desc "Re-generate all embeddings (recomputes every vector in-place)"
  task regenerate: :environment do
    model = EmbeddingConfig.resolved_config[:model]
    puts "Regenerating all embeddings (model: #{model})..."
    result = EmbeddingService.regenerate_all
    puts "Done. Re-embedded #{result[:entities]} entities, #{result[:observations]} observations."
  end

  desc "Add VECTOR INDEX after all embeddings are backfilled (requires MariaDB 11.7+)"
  task add_indexes: :environment do
    result = EmbeddingIndexManager.add_indexes!
    puts result[:message]
  rescue EmbeddingIndexManager::PrecheckError => e
    abort "ERROR: #{e.message}"
  end

  desc "Remove VECTOR INDEX and revert columns to nullable"
  task drop_indexes: :environment do
    result = EmbeddingIndexManager.drop_indexes!
    puts result[:message]
  end
end
