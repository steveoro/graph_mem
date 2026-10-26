# frozen_string_literal: true

# Undoes one change set (UI-4a): the inverse of its audit rows, or its merge snapshot, plus the
# review rows and suppressions it changed. The undo is itself a change set (kind `undo`, or `redo`
# when it undoes an undo), so it can be undone in turn.
#
#   result = ChangeSetUndo.call(uuid, actor: "operator:steve@127.0.0.1")
#   result.ok?       # => false
#   result.status    # => :conflict
#   result.conflicts # => ["Can't undo: MemoryEntity 'SynthWidget' changed since (by mcp:graph_edit at …)"]
#
# Refusals are all-or-nothing: every conflict raises inside the transaction, which rolls back.
# Lock order: the membership lock, then the transaction, then row locks (advisory-first rule).
# Entities and observations whose text the undo changed are re-embedded after the lock is released.
class ChangeSetUndo
  MAX_INLINE_EMBEDS = 50
  TIME_ZONE = "Europe/Rome"

  # Raised inside the transaction to roll the undo back.
  class Conflict < StandardError
    attr_reader :conflicts

    # @param conflicts [Array<String>]
    def initialize(conflicts)
      @conflicts = Array(conflicts)
      super(@conflicts.join("; "))
    end
  end

  # @!attribute status [Symbol] :ok, :conflict, :not_undoable, :not_found or :busy
  Result = Data.define(:status, :message, :conflicts, :change_set) do
    def ok? = status == :ok
  end

  # What the strategies changed, for the follow-up work after the rows are written.
  class Effects
    attr_reader :skipped, :entity_ids, :part_of_entity_ids, :reembed

    def initialize
      @skipped = []
      @entity_ids = Set.new
      @part_of_entity_ids = Set.new
      @reembed = Set.new
    end

    # @param record [MemoryEntity, MemoryObservation] re-embedded after the lock when its text changed
    def reembed!(record)
      @reembed << [ record.class, record.id ]
    end
  end

  # @param uuid [String] the change set to undo
  # @param actor [String, nil] recorded as undone_by and as the new set's actor
  # @return [Result]
  def self.call(uuid, actor: Current.actor)
    new(uuid, actor: actor).call
  end

  def initialize(uuid, actor:)
    @uuid = uuid.to_s
    @actor = actor
    @effects = Effects.new
  end

  # @return [Result]
  def call
    CompactionValve.request_pause_if_running!
    result = Current.set(change_set: nil) do
      ProjectMembership.with_membership_lock do
        EmbeddingService.suppress_inline_embeddings do
          ActiveRecord::Base.transaction { undo_locked }
        end
      end
    end
    reembed_changed_text if result.ok?
    result
  rescue Conflict => e
    Result.new(status: :conflict, message: "Can't undo: #{e.conflicts.size} conflict(s)", conflicts: e.conflicts, change_set: nil)
  rescue ProjectMembership::LockTimeout
    Result.new(status: :busy, message: "Busy, retry shortly", conflicts: [], change_set: nil)
  end

  private

  def undo_locked
    original = ChangeSet.lock.find_by(uuid: @uuid)
    return refusal(:not_found, "Change set not found") unless original

    reason = refusal_reason(original)
    return refusal(:not_undoable, reason) if reason

    kind = original.kind == "undo" ? "redo" : "undo"
    summary = "#{kind}: #{original.summary || original.kind}"
    ChangeSet.record(kind: kind, actor: @actor, summary: summary, subject: original.subject, undo_of: original) do |context|
      context.persist!
      dispatch(original, context)
      original.update!(undone_at: Time.current, undone_by: @actor)
      Result.new(status: :ok, message: success_message(original), conflicts: [],
                 change_set: ChangeSet.find(context.id))
    end
  end

  def dispatch(original, context)
    case original.undo_strategy
    when "audit" then AuditInverse.new(original, @effects).call
    when "merge" then raise Conflict, [ "Merge undo is not available yet" ]
    end
    ReviewRows.new(original, context, @effects).call
  end

  def refusal_reason(original)
    return "Already undone (#{local_time(original.undone_at)} by #{original.undone_by || 'unknown'})" if original.undone_at
    return "Not undoable: #{original.not_undoable_reason || 'none'}" if original.undo_strategy == "none"
    return "The undo window passed on #{local_time(original.undoable_until)}" unless original.undoable?

    nil
  end

  def refusal(status, message)
    Result.new(status: status, message: message, conflicts: [], change_set: nil)
  end

  def success_message(original)
    message = "Undone: #{original.summary || original.kind}"
    return message if @effects.skipped.empty?

    "#{message} (skipped: #{@effects.skipped.join('; ')})"
  end

  def local_time(time)
    time&.in_time_zone(TIME_ZONE)&.strftime("%Y-%m-%d %H:%M %Z")
  end

  # Best effort: the daily backfill picks up whatever is left with embedded_at NULL.
  def reembed_changed_text
    @effects.reembed.first(MAX_INLINE_EMBEDS).each do |klass, id|
      record = klass.where(embedded_at: nil).find_by(id: id)
      next unless record

      klass == MemoryEntity ? EmbeddingService.embed_entity(record) : EmbeddingService.embed_observation(record)
    rescue StandardError => e
      Rails.logger.warn "ChangeSetUndo: re-embedding #{klass.name}##{id} failed: #{e.message}"
    end
  end
end
