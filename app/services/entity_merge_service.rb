# frozen_string_literal: true

# Explore's merge (UI-4b W6): NodeOperationsStrategy#merge_into in an `explore.merge` change set,
# refused with :conflict (nothing written) when the graph changed since the operator's preview.
# The digest is recomputed inside the merge's lock and transaction, through `before_merge:`.
#
#   result = EntityMergeService.call(source_id: 41, target_id: 42, digest: preview.digest, actor: Current.actor)
#   result # => { success: true, status: :ok, message: "Successfully merged …", change_set_uuid: "…", undoable: true, … }
#          # or { success: false, status: :conflict, error: CONFLICT_MESSAGE }
class EntityMergeService
  CONFLICT_MESSAGE = "The graph changed since the preview, review it again."

  # @param source_id [Integer] merged away
  # @param target_id [Integer] the survivor
  # @param digest [String] EntityMergePreview#digest as the operator saw it
  # @param actor [String, nil] recorded on the change set and its audit rows
  # @return [Hash]
  def self.call(source_id:, target_id:, digest:, actor:)
    new(source_id.to_i, target_id.to_i, digest.to_s, actor).call
  end

  def initialize(source_id, target_id, digest, actor)
    @source_id = source_id
    @target_id = target_id
    @digest = digest
    @actor = actor
  end

  # @return [Hash]
  def call
    Current.set(actor: @actor) do
      result = NodeOperationsStrategy.new.merge_into(@source_id, @target_id, change_set_kind: "explore.merge", before_merge: method(:check_digest))
      next result.merge(status: result[:status] || :unprocessable_content) unless result[:success]

      set = ChangeSet.find_by(uuid: result[:change_set_uuid])
      result.merge(status: :ok, undoable: set ? set.undoable? : false, not_undoable_reason: set&.not_undoable_reason)
    end
  end

  private

  # Runs inside merge_into_once's lock and transaction, on the locked rows.
  def check_digest(source, target)
    EntityMergePreview.new(source.id, target.id).digest == @digest ? nil : CONFLICT_MESSAGE
  end
end
