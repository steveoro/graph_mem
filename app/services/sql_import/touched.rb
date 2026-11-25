# frozen_string_literal: true

module SqlImport
  # The rows an SQL import wrote (new, updated or claimed), read from its `import` operation row: the
  # affected list the script records in details["affected"] (kept_local and skipped_link entries
  # changed nothing and are left out). The script caps that list at 5,000 entries; past the cap the
  # rows come from the run's audit rows (reason "sql_import:<operation id>"), which name every row it
  # created or updated.
  #
  #   touched = SqlImport::Touched.for(operation)
  #   touched.entity_ids        # => [ 12, 14 ] the entities written, the owners of the facts written and the ends of the edges written
  #   touched.new_observation_ids # => [ 40, 41 ]
  class Touched
    WRITES = { "new" => "create", "updated" => "update", "claimed" => "update" }.freeze
    MODELS = { "memory_entities" => "MemoryEntity", "memory_observations" => "MemoryObservation", "memory_relations" => "MemoryRelation" }.freeze

    # @param operation [OperationProgress] an SQL import's operation row
    # @return [Touched]
    def self.for(operation)
      new(operation)
    end

    # @param operation [OperationProgress]
    def initialize(operation)
      @operation = operation
      @rows = rows # [model, id, action ("create"/"update"), fields]
    end

    # @return [Array<Integer>] new observations
    def new_observation_ids = ids("MemoryObservation", "create")

    # @return [Array<Integer>] new and updated observations
    def observation_ids = ids("MemoryObservation")

    # @return [Array<Integer>] updated observations whose tags changed
    def retagged_observation_ids
      @rows.filter_map { |model, id, action, fields| id if model == "MemoryObservation" && action == "update" && fields.include?("tags") }
    end

    # @return [Array<Integer>] the entities written, the owners of the observations written and both
    #   ends of the relations written
    def entity_ids
      @entity_ids ||= (ids("MemoryEntity") +
                       MemoryObservation.where(id: observation_ids).distinct.pluck(:memory_entity_id) +
                       MemoryRelation.where(id: ids("MemoryRelation")).pluck(:from_entity_id, :to_entity_id).flatten).uniq.sort
    end

    # @return [Array<Integer>] the entities whose observations were added or changed
    def observation_owner_ids = MemoryObservation.where(id: observation_ids).distinct.order(:memory_entity_id).pluck(:memory_entity_id)

    # @return [Array<Integer>] the entities created, updated or claimed themselves
    def written_entity_ids = ids("MemoryEntity")

    private

    def ids(model, action = nil)
      @rows.filter_map { |row_model, id, row_action, _fields| id if row_model == model && (action.nil? || row_action == action) }.uniq
    end

    def rows
      details = @operation.details.to_h
      listed = Array(details["affected"])
      return from_audit_log if details["affected_count"].to_i > listed.size

      listed.filter_map do |row|
        action = WRITES[row["action"]]
        model = MODELS[row["table"]]
        [ model, row["id"].to_i, action, Array(row["fields"]) ] if action && model && row["id"]
      end
    end

    # Every row the run created or updated (the audit rows are written in the same transaction as the
    # operation row; the created_at bound lets the query use its index).
    def from_audit_log
      AuditLog.where(actor: "sql_import", reason: "sql_import:#{@operation.operation_id}")
              .where(created_at: (@operation.created_at - 1.day)..)
              .pluck(:auditable_type, :auditable_id, :action, :changed_fields)
              .map { |model, id, action, fields| [ model, id, action, action == "update" ? fields.to_h.keys : [] ] }
    end
  end
end
