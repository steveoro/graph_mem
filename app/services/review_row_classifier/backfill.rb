# frozen_string_literal: true

class ReviewRowClassifier
  # Brings rows seeded before UI-5a up to date, in short batches (each its own transaction), so it
  # can run from the nightly policy run (bounded) or `bin/rails review:backfill` and resume anywhere:
  # 1. classify rows with no group_key;
  # 2. rewrite pending symmetric relationship proposals to the ordered signature; where two pending
  #    rows now collide, the older stays and the newer is dismissed as its duplicate;
  # 3. give suppressions with an unordered symmetric signature an ordered twin, so a dismissed B→A
  #    keeps blocking A→B.
  #
  #   ReviewRowClassifier::Backfill.call(limit: 5_000) # => { classified: 120, rewritten: 3, duplicates: 1, twins: 2 }
  class Backfill
    SIGNATURE = /\Arelationship_proposal\|(\d+)\|(\d+)\|(.+)\z/

    # @param batch_size [Integer] rows per transaction
    # @param limit [Integer, nil] most rows to classify in this call (nil = all)
    # @param progress [#call, nil] called with a message after each batch
    # @return [Hash] counts per step
    def self.call(batch_size: 1_000, limit: nil, progress: nil)
      new(batch_size, limit, progress).call
    end

    def initialize(batch_size, limit, progress)
      @batch_size = batch_size
      @limit = limit
      @progress = progress
      @counts = { classified: 0, rewritten: 0, duplicates: 0, twins: 0 }
    end

    def call
      classify_unclassified
      rewrite_symmetric_signatures
      twin_symmetric_suppressions
      @counts
    end

    private

    def classify_unclassified
      classifier = ReviewRowClassifier.new
      loop do
        room = @limit ? @limit - @counts[:classified] : @batch_size
        break unless room.positive?

        rows = MaintenanceReportRow.where(group_key: nil).order(:id).limit([ room, @batch_size ].min).to_a
        break if rows.empty?

        MaintenanceReportRow.transaction { rows.each { |row| row.update_columns(classifier.classify(row)) } }
        @counts[:classified] += rows.size
        @progress&.call("classified #{@counts[:classified]} rows")
      end
    end

    def rewrite_symmetric_signatures
      MaintenanceReportRow.pending.where(kind: "relationship_proposal").in_batches(of: @batch_size) do |batch|
        MaintenanceReportRow.transaction do
          batch.order(:id).each do |row|
            signature = CompactionReviewService.signature_for(row.kind, row.effective_payload)
            next if signature.blank? || signature == row.signature

            rewrite(row, signature)
          end
        end
      end
      @progress&.call("symmetric signatures: #{@counts[:rewritten]} rewritten, #{@counts[:duplicates]} duplicates")
    end

    def rewrite(row, signature)
      older = MaintenanceReportRow.by_report_type(row.report_type).pending.where(signature: signature)
                                  .where.not(id: row.id).order(:id).first
      if older && older.id < row.id
        row.update_columns(status: "dismissed", dismissed_at: Time.current, resolved_by: "generator",
                           resolution_reason: "duplicate of ##{older.id}", updated_at: Time.current)
        @counts[:duplicates] += 1
      elsif older
        older.update_columns(status: "dismissed", dismissed_at: Time.current, resolved_by: "generator",
                             resolution_reason: "duplicate of ##{row.id}", updated_at: Time.current)
        row.update_columns(signature: signature)
        @counts[:duplicates] += 1
      else
        row.update_columns(signature: signature)
        @counts[:rewritten] += 1
      end
    end

    def twin_symmetric_suppressions
      MaintenanceReportSuppression.where("signature LIKE ?", "relationship\\_proposal|%").find_each do |suppression|
        match = SIGNATURE.match(suppression.signature)
        next unless match && RelationSemantics.symmetric?(match[3]) && match[1].to_i > match[2].to_i

        twin = "relationship_proposal|#{match[2]}|#{match[1]}|#{match[3]}"
        next if MaintenanceReportSuppression.exists?(report_type: suppression.report_type, signature: twin)

        MaintenanceReportSuppression.create!(suppression.attributes.except("id", "signature", "created_at", "updated_at")
                                                        .merge("signature" => twin))
        @counts[:twins] += 1
      end
    end
  end
end
