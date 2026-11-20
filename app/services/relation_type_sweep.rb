# frozen_string_literal: true

# Canonicalizes the relation types already stored (R1a, plan item 3). The single implementation
# behind the dream-state phase `relation_types`, `bin/rails graph_mem:canonicalize_relations` and
# RelationTypeSweepJob. Relations are read in batches of BATCH_SIZE by id cursor; for each one the
# target type is MemoryRelation.canonical_relation_type of the stored type (followed until stable),
# and then:
#
# - same type (byte-identical): nothing ("unchanged");
# - same type as the database compares it (`utf8mb4_general_ci`: case, trailing spaces): a plain
#   update ("case_only"). The unique key (from, to, type) compares the same way, so the row is its
#   own twin and can't collide;
# - another type, no other row of the target type on the same endpoints: retyped in place
#   ("retyped"), except when the target is `part_of`;
# - another type, a twin of the target type on the same endpoints: the variant is merged into the
#   twin (higher weight and confidence kept; properties: see #merged_properties) and deleted
#   ("merged"). A `part_of` twin too: the edge already exists, so membership doesn't change;
# - target `part_of`, no twin: never written here (an update skips the create-time single-parent
#   and cycle checks and ProjectMembership.sync!). A `relation_retype` review row is queued instead
#   ("queued"), once: a row already pending, or a dismissed suggestion, is "already_queued";
# - a stored `part_of` whose target is another type (it can't happen: a vocabulary type always
#   maps to itself): left alone ("skipped_part_of"), as retyping out of `part_of` would move
#   membership without a sync.
#
# Locks: no write here creates, deletes or retypes a `part_of` edge (part_of candidates are only
# queued; a case-only fix of a stored `Part_Of` and a delete of a variant merged into a `part_of`
# twin leave the edges SQL reads as `part_of` as they were), so the sweep never takes the
# membership lock, and it can run inside the compactor's transaction.
#
# Writes go through normal saves (Auditable: every change is an audit row in the batch's change
# set, actor included). Each batch that writes is one change set of kind `dream.relation_types`,
# never undoable through the generic undo (ChangeSet::NOT_UNDOABLE_KINDS). Trust scores are
# recomputed once per endpoint of a merged (deleted) variant; a retype doesn't change them.
#
#   RelationTypeSweep.call(dry_run: true)
#   # => { dry_run: true, counts: { "scanned" => 812, "unchanged" => 790, "retyped" => 19, ... },
#   #      changes: [{ "relation_id" => 41, "action" => "retyped", "old_type" => "Has Many", ... }],
#   #      changes_omitted: 0, report_id: nil }
class RelationTypeSweep
  BATCH_SIZE = 200
  CHANGE_SET_KIND = "dream.relation_types"
  DEFAULT_ACTOR = "job:relation_type_sweep"
  REPORT_TYPE = "relation_type_sweep"
  REVIEW_KIND = "relation_retype"
  REVIEW_REPORT_TYPE = "compaction_review"
  PART_OF = "part_of"
  # Most change entries one report (or a dry run's answer) lists; the counts always cover all.
  MAX_REPORTED_CHANGES = 2_000
  # One per relation scanned: they add up to "scanned".
  OUTCOMES = %w[unchanged case_only retyped merged queued already_queued skipped_part_of error].freeze
  WRITE_ACTIONS = %w[case_only retyped merged].freeze
  MAX_TARGET_STEPS = 5

  # What the sweep will do with one relation.
  Plan = Struct.new(:relation_id, :from_entity_id, :to_entity_id, :old_type, :new_type, :action, :twin_id,
                    keyword_init: true)
  # @!attribute scanned [Integer] relations read (0 = the cursor is past the last relation)
  # @!attribute last_id [Integer] the cursor for the next batch
  # @!attribute counts [Hash{String => Integer}] this batch's outcomes, plus "scanned"
  # @!attribute changes [Array<Hash>] this batch's change entries (see #entry)
  Batch = Data.define(:scanned, :last_id, :counts, :changes)

  include Report

  # Runs the whole sweep, batch after batch. It first drops this process's mapping cache
  # (RelationTypeMapping::CANONICALIZE_TTL), so a mapping the operator has just added in the web
  # process is seen by a sweep the job worker starts right after it.
  #
  # @param dry_run [Boolean] plan only: nothing is written, not even the report; same counts
  # @param actor [String] audit and change-set actor
  # @param source [String] who ran it ("rake", "operator", "dream_state"), stored on the report
  # @param progress [#call, nil] called with the sweep after each batch
  # @return [Hash] see #summary
  def self.call(dry_run: false, actor: DEFAULT_ACTOR, source: "manual", progress: nil)
    RelationTypeMapping.reset_canonicalize_cache!
    sweep = new(dry_run: dry_run, actor: actor, source: source)
    cursor = 0
    loop do
      batch = sweep.process_batch(after_id: cursor)
      break if batch.scanned.zero?

      cursor = batch.last_id
      progress&.call(sweep)
      break if batch.scanned < sweep.batch_size
    end
    sweep.finish!
  end

  # The type a stored type is canonicalized to: MemoryRelation.canonical_relation_type, applied
  # again while it still changes (an operator mapping chain A → B → C gives C), so the save
  # callback stores exactly this type.
  #
  # @param stored_type [String, nil]
  # @return [String, nil]
  def self.target_type(stored_type)
    current = MemoryRelation.canonical_relation_type(stored_type)
    MAX_TARGET_STEPS.times do
      following = MemoryRelation.canonical_relation_type(current)
      break if following.blank? || following == current

      current = following
    end
    current
  end

  # @param type [String, nil]
  # @return [Boolean] true when the type is `part_of` once folded
  def self.part_of?(type)
    MemoryRelation.fold_relation_type(type) == PART_OF
  end

  # @param relation_id [Integer]
  # @param type [String]
  # @return [Boolean] true when the stored type of the relation equals `type` as the database
  #   compares it (the column's collation, like the unique key)
  def self.stored_as?(relation_id, type)
    MemoryRelation.where(id: relation_id, relation_type: type).exists?
  end

  # @param from_entity_id [Integer]
  # @param to_entity_id [Integer]
  # @param type [String]
  # @param except_id [Integer] the relation itself, never its own twin
  # @return [Integer, nil] the id of another relation of `type` on the same endpoints (database comparison)
  def self.twin_id(from_entity_id, to_entity_id, type, except_id:)
    MemoryRelation.where(from_entity_id: from_entity_id, to_entity_id: to_entity_id, relation_type: type)
                  .where.not(id: except_id).pick(:id)
  end

  # Merges a variant row into its twin (same endpoints, the type the variant becomes) and deletes
  # the variant: the twin keeps the higher weight and confidence, and the properties rule of
  # .merged_properties. The twin's own type is left as stored. Used by the sweep and by a
  # relation_retype row kept as relates_to (CompactionReviewApplier::RelationRetype).
  #
  # @param variant [MemoryRelation]
  # @param twin [MemoryRelation] locked by the caller
  # @param reason [String] the delete's audit reason
  # @return [MemoryRelation] the twin
  def self.merge_into_twin!(variant, twin, reason:)
    twin.assign_attributes(weight: [ twin.weight, variant.weight ].compact.max,
                           confidence: [ twin.confidence, variant.confidence ].compact.max,
                           properties: merged_properties(twin, variant))
    twin.save! if twin.changed?
    Current.set(deletion_reason: reason) { variant.destroy! }
    twin
  end

  # The twin keeps its own properties. When it has none it takes the variant's; otherwise the
  # variant's (when it has any) are kept under "merged_from", one entry per merged variant, so
  # nothing is lost. (Entity merges and the integrity repair drop a duplicate edge's properties;
  # there was no earlier rule for a merge that keeps a row.)
  #
  # @param twin [MemoryRelation]
  # @param variant [MemoryRelation]
  # @return [Hash]
  def self.merged_properties(twin, variant)
    mine = twin.properties.is_a?(Hash) ? twin.properties : {}
    theirs = variant.properties.is_a?(Hash) ? variant.properties : {}
    return mine if theirs.empty?
    return theirs if mine.empty?

    merged_from = Array(mine["merged_from"]) + [ { "relation_id" => variant.id, "relation_type" => variant.relation_type,
                                                   "properties" => theirs } ]
    mine.merge("merged_from" => merged_from)
  end

  attr_reader :batch_size, :counts

  # @param dry_run [Boolean]
  # @param actor [String]
  # @param source [String]
  # @param source_ref [Object, nil] e.g. the compaction run id; stored on the report and on the
  #   review rows' report
  # @param report_id [Integer, nil] an existing report to append to (the dream-state phase runs one
  #   batch per job and keeps the id on the run)
  # @param batch_size [Integer]
  def initialize(dry_run: false, actor: DEFAULT_ACTOR, source: "manual", source_ref: nil, report_id: nil,
                 batch_size: BATCH_SIZE)
    @dry_run = dry_run
    @actor = actor
    @source = source
    @source_ref = source_ref
    @report_id = report_id
    @batch_size = batch_size
    @counts = Hash.new(0)
    @changes = []
    @omitted = 0
    # (from, to, folded target) => relation id, for each relation planned as "retyped" in this run:
    # a later variant of the same type on the same endpoints plans as "merged" into it, so a dry
    # run counts what the real run does (where the first retype has landed by then).
    @claimed = {}
    @targets = {}
  end

  # Plans and (unless dry) applies the relations after `after_id`, at most batch_size of them.
  #
  # @param after_id [Integer] the cursor: the last relation id of the previous batch (0 to start)
  # @return [Batch]
  def process_batch(after_id: 0)
    rows = MemoryRelation.where("id > ?", after_id.to_i).order(:id).limit(@batch_size)
                         .pluck(:id, :from_entity_id, :to_entity_id, :relation_type)
    return Batch.new(scanned: 0, last_id: after_id.to_i, counts: {}, changes: []) if rows.empty?

    plans = rows.filter_map { |row| plan_for(*row) }
    changes = @dry_run ? dry_changes(plans) : apply(plans)
    counts = tally(rows.size, changes)
    remember(counts, changes)
    Batch.new(scanned: rows.size, last_id: rows.last.first, counts: counts, changes: changes)
  end

  private

  # @param claims [Boolean] also count the retypes planned earlier in this run as twins (planning);
  #   false re-plans from the stored rows only (under the lock, before writing)
  # @return [Plan, nil] nil when the relation is already canonical (byte-identical)
  def plan_for(relation_id, from_entity_id, to_entity_id, stored_type, claims: true)
    target = @targets.fetch(stored_type) { @targets[stored_type] = self.class.target_type(stored_type) }
    return nil if target.blank? || target == stored_type

    plan = Plan.new(relation_id: relation_id, from_entity_id: from_entity_id, to_entity_id: to_entity_id,
                    old_type: stored_type, new_type: target)
    plan.action = action_for(plan, claims)
    @claimed[claim_key(plan)] ||= plan.relation_id if claims && plan.action == "retyped"
    plan
  end

  def claim_key(plan)
    [ plan.from_entity_id, plan.to_entity_id, MemoryRelation.fold_relation_type(plan.new_type) ]
  end

  def action_for(plan, claims)
    return "case_only" if self.class.stored_as?(plan.relation_id, plan.new_type)
    # A stored part_of (as SQL reads it) can't canonicalize to another type today: RelationTypeMapping
    # maps every vocabulary type to itself before any table row, and part_of is no other type's
    # variant. Guarded anyway: retyping it in place would move membership without a sync.
    return "skipped_part_of" if self.class.stored_as?(plan.relation_id, PART_OF)

    plan.twin_id = self.class.twin_id(plan.from_entity_id, plan.to_entity_id, plan.new_type, except_id: plan.relation_id)
    plan.twin_id ||= @claimed[claim_key(plan)] if claims
    return "merged" if plan.twin_id
    return "queue" if self.class.part_of?(plan.new_type)

    "retyped"
  end

  def tally(scanned, changes)
    counts = { "scanned" => scanned }
    counts["unchanged"] = scanned - changes.size
    changes.each { |change| counts[change["action"]] = counts.fetch(change["action"], 0) + 1 }
    counts
  end

  # --- dry run ---------------------------------------------------------------------------------

  def dry_changes(plans)
    plans.map do |plan|
      next entry(plan, plan.action, merged_into_id: plan.twin_id) unless plan.action == "queue"

      pending = queued_row(plan)
      pending ? entry(plan, "already_queued", review_row_id: pending.presence) : entry(plan, "queued")
    end
  end

  # --- writes ----------------------------------------------------------------------------------

  def apply(plans)
    writes, others = plans.partition { |plan| WRITE_ACTIONS.include?(plan.action) }
    queues, skipped = others.partition { |plan| plan.action == "queue" }
    (write_batch(writes) + skipped.map { |plan| entry(plan, plan.action) } + queue(queues))
      .sort_by { |change| change["relation_id"] }
  end

  # One change set (non-undoable kind) and one transaction for the batch's writes; each relation
  # in its own savepoint, so one failure is reported and the others still land.
  def write_batch(plans)
    return [] if plans.empty?

    touched = Set.new
    context = nil
    changes = Current.set(actor: @actor, change_set: nil) do
      MemoryRelation.suppress_trust_recompute do
        ChangeSet.record(kind: CHANGE_SET_KIND, actor: @actor, summary: "relation types canonicalized") do |change_set|
          context = change_set
          ActiveRecord::Base.transaction(requires_new: true) { plans.map { |plan| write_one(plan, touched) } }
        end
      end
    end
    MemoryRelation.recompute_trust_scores_for(touched)
    note_change_set(context, changes)
    changes
  end

  def write_one(plan, touched)
    ActiveRecord::Base.transaction(requires_new: true) do
      relation = MemoryRelation.lock.find_by(id: plan.relation_id)
      fresh = relation && plan_for(relation.id, relation.from_entity_id, relation.to_entity_id, relation.relation_type, claims: false)
      if relation.nil?
        entry(plan, "error", error: "deleted during the sweep")
      elsif fresh.nil?
        entry(plan, "unchanged")
      elsif fresh.new_type != plan.new_type || !WRITE_ACTIONS.include?(fresh.action)
        # Still a write to the same type is fine (a retype planned before a sibling variant took the
        # type on these endpoints is now a merge into it, or the other way round when that one failed).
        entry(plan, "error", error: "changed during the sweep; left for the next one")
      else
        write!(relation, fresh, touched)
      end
    end
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ActiveRecord::RecordNotDestroyed => e
    entry(plan, "error", error: e.message.to_s.truncate(200))
  end

  def write!(relation, plan, touched)
    return merge!(relation, plan, touched) if plan.action == "merged"

    relation.update!(relation_type: plan.new_type)
    entry(plan, plan.action)
  end

  def merge!(relation, plan, touched)
    twin = MemoryRelation.lock.find(plan.twin_id)
    self.class.merge_into_twin!(relation, twin, reason: "relation type canonicalized: merged into ##{twin.id}")
    touched.merge([ relation.from_entity_id, relation.to_entity_id ])
    entry(plan, "merged", merged_into_id: twin.id)
  end

  # --- review rows -----------------------------------------------------------------------------

  def queue(plans)
    return [] if plans.empty?

    pending, fresh = plans.partition { |plan| queued_row(plan) }
    # The child's current part_of parent (another entity, or the twin would have merged): the row
    # then asks to move or keep (CompactionReviewApplier::RelationRetype).
    parents = MemoryRelation.where(from_entity_id: fresh.map(&:from_entity_id), relation_type: PART_OF)
                            .pluck(:from_entity_id, :to_entity_id).to_h
    ids = fresh.flat_map { |plan| [ plan.from_entity_id, plan.to_entity_id ] } + parents.values
    names = MemoryEntity.where(id: ids).pluck(:id, :name).to_h
    rows = CompactionReviewService.seed_report(report_type: REVIEW_REPORT_TYPE, source: REPORT_TYPE, source_ref: @source_ref,
                                               items: fresh.map { |plan| review_item(plan, names, parent_id: parents[plan.from_entity_id]) })
    seeded = rows.index_by { |row| row.payload["relation_id"].to_i }
    pending.map { |plan| entry(plan, "already_queued", review_row_id: queued_row(plan).presence) } +
      fresh.map do |plan|
        row = seeded[plan.relation_id]
        row ? entry(plan, "queued", review_row_id: row.row_uuid) : entry(plan, "error", error: "not queued: the review backlog is full")
      end
  end

  # @return [String, nil] the uuid of the pending row ("" when the suggestion was dismissed), nil
  #   when a row would be seeded (the checks CompactionReviewService.seed_report makes)
  def queued_row(plan)
    signature = CompactionReviewService.signature_for(REVIEW_KIND, review_item(plan, {}))
    pending = MaintenanceReportRow.by_report_type(REVIEW_REPORT_TYPE).pending.where(signature: signature).pick(:row_uuid)
    return pending if pending
    return "" if MaintenanceReportSuppression.suppressed?(REVIEW_REPORT_TYPE, signature)

    nil
  end

  # @param parent_id [Integer, nil] the child's current part_of parent, when it has one
  def review_item(plan, names, parent_id: nil)
    {
      id: SecureRandom.uuid, kind: REVIEW_KIND, operation: "retype", relation_id: plan.relation_id,
      from_entity_id: plan.from_entity_id, from_name: names[plan.from_entity_id],
      to_entity_id: plan.to_entity_id, to_name: names[plan.to_entity_id],
      old_type: plan.old_type, new_type: plan.new_type, reason: review_reason(plan, names, parent_id)
    }
  end

  def review_reason(plan, names, parent_id)
    reason = "'#{plan.old_type}' is a variant of #{plan.new_type}; a #{plan.new_type} edge moves membership, " \
             "so it is created by hand (Apply), never by the sweep"
    return reason unless parent_id

    "#{reason}. '#{names[plan.from_entity_id]}' is already #{plan.new_type} '#{names[parent_id]}': choose to move it " \
      "under '#{names[plan.to_entity_id]}', or to keep its parent (the variant then becomes relates_to)"
  end

  # One change entry of the report.
  def entry(plan, action, merged_into_id: nil, review_row_id: nil, error: nil)
    {
      "relation_id" => plan.relation_id, "action" => action, "old_type" => plan.old_type, "new_type" => plan.new_type,
      "from_entity_id" => plan.from_entity_id, "to_entity_id" => plan.to_entity_id,
      "merged_into_id" => merged_into_id, "review_row_id" => review_row_id, "error" => error
    }.compact
  end
end
