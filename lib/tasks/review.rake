# frozen_string_literal: true

namespace :review do
  desc "Classify review rows seeded before UI-5a and dedupe symmetric relationship proposals (resumable)"
  task backfill: :environment do
    counts = ReviewRowClassifier.backfill!(progress: ->(message) { puts message })
    puts "Done: #{counts.map { |step, count| "#{step} #{count}" }.join(', ')}"
  end
end
