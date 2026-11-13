# frozen_string_literal: true

namespace :review do
  desc "Classify review rows seeded before UI-5a and dedupe symmetric relationship proposals (resumable)"
  task backfill: :environment do
    counts = ReviewRowClassifier.backfill!(progress: ->(message) { puts message })
    puts "Done: #{counts.map { |step, count| "#{step} #{count}" }.join(', ')}"
  end

  desc "Count what the still_qualifies policy would dismiss, per kind (read-only, 1.85.0)"
  task still_qualifies_report: :environment do
    ReviewPolicies::StillQualifies.preview.each do |kind, counts|
      puts "[still_qualifies] #{kind}: #{counts['pending']} pending; #{counts['below_bar']} below the current evidence bar"
    end
    puts "[still_qualifies] the policy is #{AppSettings.review_policy_enabled?('still_qualifies') ? 'on' : 'off'}"
  end
end
