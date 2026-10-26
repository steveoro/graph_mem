# frozen_string_literal: true

class ChangeSetUndo
  # Inverts a change set's audit rows, newest first: a create is destroyed, an update gets its
  # `from` values back, a relation delete is re-inserted with its original id. Runs inside
  # ChangeSetUndo's lock and transaction; every problem is collected and raised as one Conflict.
  class AuditInverse
    # Derived or bookkeeping columns: never written back.
    IGNORED = %w[updated_at embedded_at trust_score memory_observations_count project_id project_scope].freeze
    MODELS = { "MemoryEntity" => MemoryEntity, "MemoryObservation" => MemoryObservation, "MemoryRelation" => MemoryRelation }.freeze

    # @param change_set [ChangeSet] the set being undone
    # @param effects [ChangeSetUndo::Effects]
    def initialize(change_set, effects)
      @change_set = change_set
      @effects = effects
      @conflicts = []
    end

    # @raise [ChangeSetUndo::Conflict]
    def call
      rows = @change_set.audit_logs.order(id: :desc).to_a
      check_later_changes!(rows)
      rows.each { |row| invert(row) }
      sync_memberships
      recount_observations
      raise Conflict, @conflicts if @conflicts.any?
    end

    private

    # All-or-nothing: refuse when any touched record has an audit row newer than this set's own,
    # written by anything other than this set (or an earlier undo of it).
    def check_later_changes!(rows)
      return if rows.empty?

      own_ids = [ @change_set.id ] + @change_set.undos.pluck(:id)
      newest = rows.group_by { |row| [ row.auditable_type, row.auditable_id ] }.transform_values { |list| list.map(&:id).max }
      newest.keys.group_by(&:first).each do |type, keys|
        AuditLog.where(auditable_type: type, auditable_id: keys.map(&:last))
                .where("id > ?", rows.map(&:id).min)
                .where("change_set_id IS NULL OR change_set_id NOT IN (?)", own_ids)
                .order(:id).each do |later|
          next unless later.id > newest[[ type, later.auditable_id ]]

          @conflicts << "Can't undo: #{label(type, later.auditable_id, later)} changed since " \
                        "(by #{later.actor || 'unknown'} at #{later.created_at.in_time_zone(TIME_ZONE).strftime('%Y-%m-%d %H:%M %Z')})"
        end
      end
      raise Conflict, @conflicts.uniq if @conflicts.any?
    end

    def invert(row)
      model = MODELS[row.auditable_type]
      return @conflicts << "Can't undo a #{row.auditable_type} change" unless model

      case row.action
      when "create" then invert_create(model, row)
      when "update" then invert_update(model, row)
      when "delete" then invert_delete(model, row)
      end
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotDestroyed, ActiveRecord::RecordNotUnique,
           RelationSemantics::ValidationError => e
      @conflicts << "Can't undo #{label(row.auditable_type, row.auditable_id, row)}: #{e.message}"
    end

    def invert_create(model, row)
      record = model.lock.find_by(id: row.auditable_id)
      return @conflicts << "#{label(row.auditable_type, row.auditable_id, row)} no longer exists" unless record

      note_touched(record)
      case record
      when MemoryObservation
        # A replacement others point at can't vanish: retire it instead.
        return record.mark_obsolete!(reason: "undone") if MemoryObservation.exists?(superseded_by_id: record.id)
      when MemoryEntity
        return @conflicts << "Can't undo: #{label(row.auditable_type, record.id, row)} now has observations or relations" if in_use?(record)
      end
      record.destroy!
    end

    def invert_update(model, row)
      changes = row.changed_fields.to_h.except(*IGNORED)
      return if changes.empty?

      record = model.lock.find_by(id: row.auditable_id)
      return @conflicts << "#{label(row.auditable_type, row.auditable_id, row)} no longer exists" unless record

      drifted = changes.keys.reject { |field| same_value?(record[field], changes[field]["to"]) }
      if drifted.any?
        return @conflicts << "Can't undo: #{label(row.auditable_type, record.id, row)} no longer holds the changed #{drifted.join(', ')}"
      end

      record.assign_attributes(changes.transform_values { |change| change["from"] })
      @effects.reembed!(record) if record.respond_to?(:embedded_at) && (record.changed & model::EMBEDDING_FIELDS).any?
      record.save!
      note_touched(record)
    end

    # Only relation deletes reach here: entity and observation deletes make the set not undoable.
    def invert_delete(model, row)
      return @conflicts << "Can't re-create a deleted #{row.auditable_type}" unless model == MemoryRelation

      attrs = row.changed_fields.to_h.slice(*MemoryRelation.column_names)
      problem = relation_restore_problem(attrs)
      return @conflicts << "Can't re-create relation ##{attrs['id']}: #{problem}" if problem

      relation = MemoryRelation.create!(attrs)
      note_touched(relation)
    end

    def relation_restore_problem(attrs)
      return "its id is taken" if MemoryRelation.exists?(id: attrs["id"])
      return "an endpoint is gone" unless MemoryEntity.where(id: [ attrs["from_entity_id"], attrs["to_entity_id"] ]).count == 2
      if MemoryRelation.exists?(attrs.slice("from_entity_id", "to_entity_id", "relation_type"))
        return "the same relation exists again"
      end
      return "it would create a part_of cycle" if attrs["relation_type"] == "part_of" &&
                                                  RelationSemantics.would_create_cycle?(attrs["from_entity_id"], attrs["to_entity_id"])

      nil
    end

    def in_use?(entity)
      entity.memory_observations.exists? ||
        MemoryRelation.where(from_entity_id: entity.id).or(MemoryRelation.where(to_entity_id: entity.id)).exists?
    end

    # Values come back from JSON (times at millisecond precision): compare in that form.
    def same_value?(current, stored)
      current.as_json == stored
    end

    def note_touched(record)
      case record
      when MemoryEntity then @effects.entity_ids << record.id
      when MemoryObservation then @effects.entity_ids.merge([ record.memory_entity_id, record.memory_entity_id_before_last_save ].compact)
      when MemoryRelation
        @effects.part_of_entity_ids << record.from_entity_id if record.relation_type == "part_of"
      end
    end

    def sync_memberships
      @effects.part_of_entity_ids.each do |entity_id|
        entity = MemoryEntity.find_by(id: entity_id)
        ProjectMembership.sync!(entity) if entity
      rescue ProjectMembership::Collision => e
        @conflicts << "Can't undo: #{e.message}"
      end
    end

    def recount_observations
      @effects.entity_ids.each do |entity_id|
        MemoryEntity.where(id: entity_id).update_all(memory_observations_count: MemoryObservation.where(memory_entity_id: entity_id).count)
      end
    end

    def label(type, id, row)
      record = MODELS[type]&.find_by(id: id)
      fields = row.respond_to?(:changed_fields) ? row.changed_fields.to_h : {}
      name = case type
      when "MemoryEntity" then record&.name || fields["name"] || fields.dig("name", "from")
      when "MemoryObservation" then (record&.content || fields["content"]).to_s.truncate(40)
      when "MemoryRelation" then record ? "#{record.from_entity_id} #{record.relation_type} #{record.to_entity_id}" : nil
      end
      name.present? ? "#{type} '#{name}'" : "#{type} ##{id}"
    end
  end
end
