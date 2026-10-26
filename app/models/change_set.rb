# frozen_string_literal: true

# A change set groups the writes of one user-visible change (a graph_write batch, a merge, a
# review action) so an operator can undo them together (UI-4a, docs/architecture.md "Change sets
# and undo"). Audit rows point at their set through `audit_logs.change_set_id`; merges and review
# actions also store what the audit trail lacks in `snapshot`.
#
# Recording is lazy: {.record} only puts a {ChangeSet::Context} in `Current.change_set`; the row
# is inserted by the first write that needs it, inside that write's transaction, so a change set
# with no changes never exists and a rolled-back write takes its set with it.
#
#   ChangeSet.record(kind: "graph.edit") { GraphEditService.call(operations: ops) }
#   ChangeSet.find_by(uuid: uuid).undoable? # => true within the window
class ChangeSet < ApplicationRecord
  KINDS = %w[
    merge compaction.auto_merge graph.write graph.edit graph.delete
    review.apply review.bulk_apply review.dismiss review.bulk_dismiss review.restore review.ignore review.snooze
    api.write maintenance.merge_node undo redo
  ].freeze
  # Reserved for UI-5 policy runs and UI-4b Explore actions.
  KIND_PATTERNS = [ /\Apolicy\.[a-z_]+\z/, /\Aexplore\.[a-z_]+\z/ ].freeze
  STRATEGIES = %w[audit merge none].freeze
  NOT_UNDOABLE_REASONS = %w[hard_delete mixed_merge audit_incomplete snapshot_too_large].freeze
  WINDOWS = { "merge" => 7.days, "audit" => 30.days }.freeze
  MAX_SNAPSHOT_BYTES = 4.megabytes
  SNAPSHOT_VERSION = 1

  serialize :snapshot, coder: JSON

  belongs_to :undo_of, class_name: "ChangeSet", optional: true
  has_many :undos, class_name: "ChangeSet", foreign_key: :undo_of_id, inverse_of: :undo_of, dependent: nil
  has_many :audit_logs, dependent: nil

  validates :uuid, presence: true
  validates :kind, presence: true
  validate :kind_is_known
  validates :undo_strategy, inclusion: { in: STRATEGIES }
  validates :not_undoable_reason, inclusion: { in: NOT_UNDOABLE_REASONS }, allow_nil: true

  # @param kind [String] one of KINDS or matching KIND_PATTERNS
  # @return [Boolean]
  def self.valid_kind?(kind)
    KINDS.include?(kind.to_s) || KIND_PATTERNS.any? { |pattern| pattern.match?(kind.to_s) }
  end

  # Runs the block with a change set open in `Current.change_set`. Inside an open set it joins
  # that set (the arguments are ignored): a merge inside a graph_delete batch or a review apply
  # belongs to the outer change. Opens no transaction and takes no lock.
  #
  # @param kind [String] see KINDS
  # @param summary [String, nil] one line for the history ("merged 'A' into 'B'")
  # @param subject [ActiveRecord::Base, nil] anchor record; nil = the first entity written
  # @param actor [String, nil] defaults to Current.actor
  # @param undo_of [ChangeSet, nil] the set this one undoes (kinds undo/redo)
  # @yieldparam context [ChangeSet::Context]
  # @return [Object] the block's value
  def self.record(kind:, summary: nil, subject: nil, actor: Current.actor, undo_of: nil)
    return yield(Current.change_set) if Current.change_set
    raise ArgumentError, "unknown change set kind: #{kind}" unless valid_kind?(kind)

    context = Context.new(kind: kind, summary: summary, subject: subject, actor: actor, undo_of: undo_of)
    Current.set(change_set: context) { yield context }
  end

  # A record's columns as snapshot JSON, keeping times at microsecond precision (plain as_json
  # rounds them to milliseconds).
  # @param record [ActiveRecord::Base]
  # @return [Hash{String => Object}]
  def self.snapshot_attributes(record)
    record.attributes.transform_values { |value| value.acts_like?(:time) ? value.utc.iso8601(6) : value.as_json }
  end

  # @param now [Time]
  # @return [Boolean] true while the set can still be undone
  def undoable?(now = Time.current)
    undo_strategy != "none" && undone_at.nil? && undoable_until.present? && undoable_until > now
  end

  # @return [ActiveRecord::Base, nil] the anchor record, if it still exists
  def subject
    subject_type.presence && subject_type.safe_constantize&.find_by(id: subject_id)
  end

  # @param name [String, Symbol] a snapshot section ("merges", "review_rows", ...)
  # @return [Array<Hash>] the section's entries (empty when absent or pruned)
  def section(name)
    Array(snapshot.is_a?(Hash) ? snapshot[name.to_s] : nil)
  end

  private

  def kind_is_known
    errors.add(:kind, "is not a known change set kind") unless self.class.valid_kind?(kind)
  end
end
