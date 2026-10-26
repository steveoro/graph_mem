# frozen_string_literal: true

class ChangeSetUndo
  # Undoes the merge steps of a change set, newest first, from their EntityMergeSnapshot: the
  # source comes back with its original id and vector bytes, its observations and edges return,
  # and the aliases the merge added to the target are removed. Undoing that undo (redo) re-runs
  # the merges, which records fresh snapshots, so a redo is undoable too.
  # Runs inside ChangeSetUndo's lock and transaction; any refusal raises a Conflict.
  class Merge
    NOT_RESTORED = %w[embedding embedding_hex project_scope memory_observations_count updated_at].freeze

    # @param change_set [ChangeSet] the set being undone
    # @param context [ChangeSet::Context] the undo set being recorded
    # @param effects [ChangeSetUndo::Effects]
    def initialize(change_set, context, effects)
      @change_set = change_set
      @context = context
      @effects = effects
    end

    # @raise [ChangeSetUndo::Conflict]
    def call
      steps = @change_set.section(:merges)
      return redo_merges if steps.empty?

      @context.within_merge_step { steps.reverse_each { |step| undo_step(step) } }
      @context.note_redo_merges!(steps.map { |step| { "source_id" => step.dig("source", "id"), "target_id" => step.dig("target", "id") } })
    end

    private

    def redo_merges
      @change_set.section(:redo_merges).each do |pair|
        result = NodeOperationsStrategy.new.merge_into(pair["source_id"], pair["target_id"], change_set_kind: "redo")
        raise Conflict, [ "Can't redo the merge: #{result[:error]}" ] unless result[:success]
      end
    end

    def undo_step(step)
      source = step["source"]
      target = lock_entities(step)[step.dig("target", "id")]
      conflicts = refusals(step, target)
      raise Conflict, conflicts if conflicts.any?

      restored = restore_source(source)
      MemoryObservation.where(id: step["observation_ids"]).order(:id).each { |obs| obs.update!(memory_entity_id: restored.id) }
      restore_relations(step)
      remove_added_aliases(target, step["target"])
      finish(step, restored, target)
    end

    def lock_entities(step)
      ids = [ step.dig("target", "id") ] + step["children"].map(&:first) +
            (step["repointed"] + step["destroyed"]).flat_map { |r| [ r["from_entity_id"] || r["from_after"], r["to_entity_id"] || r["to_after"] ] }
      MemoryEntity.where(id: ids.compact.uniq - [ step.dig("source", "id") ]).order(:id).lock.index_by(&:id)
    end

    # Collect every reason at once, so the operator sees the whole list.
    def refusals(step, target)
      source = step["source"]
      conflicts = []
      conflicts << target_gone(step.dig("target", "id")) unless target
      conflicts << "Can't undo: an entity with id #{source['id']} exists again" if MemoryEntity.exists?(id: source["id"])
      conflicts.concat(scope_refusals(source))
      owned = MemoryObservation.where(id: step["observation_ids"], memory_entity_id: step.dig("target", "id")).lock.count
      if owned < step["observation_ids"].size
        conflicts << "Can't undo: #{step['observation_ids'].size - owned} observation(s) moved or deleted since the merge"
      end
      conflicts.concat(repointed_refusals(step["repointed"]))
    end

    def target_gone(target_id)
      deletion = AuditLog.where(auditable_type: "MemoryEntity", auditable_id: target_id, action: "delete").order(:id).last
      later = deletion&.change_set
      return "Can't undo: the merge target ##{target_id} is gone" unless later

      "Can't undo: the merge target ##{target_id} was removed by change #{later.uuid} (#{later.kind}); undo #{later.uuid} first"
    end

    def scope_refusals(source)
      project_id = source["project_id"]
      if project_id && !MemoryEntity.exists?(id: project_id, entity_type: NodeOperationsStrategy::PROJECT_ENTITY_TYPE)
        return [ "Can't undo: the project ##{project_id} of '#{source['name']}' is gone" ]
      end
      return [] unless MemoryEntity.where(project_id: project_id, name: source["name"]).exists?

      [ "Can't undo: an entity named '#{source['name']}' exists again in its scope" ]
    end

    def repointed_refusals(entries)
      current = MemoryRelation.where(id: entries.map { |entry| entry["id"] }).lock.index_by(&:id)
      entries.filter_map do |entry|
        relation = current[entry["id"]]
        next "Can't undo: relation ##{entry['id']} was deleted since the merge" unless relation
        next if relation.from_entity_id == entry["from_after"] && relation.to_entity_id == entry["to_after"]

        "Can't undo: relation ##{entry['id']} (#{entry['relation_type']}) was moved since the merge"
      end
    end

    # The source's own row: original id and columns; the vector bytes and created_at are written
    # with one statement (no re-embedding, no zero-vector placeholder).
    def restore_source(attrs)
      entity = MemoryEntity.new(attrs.except(*NOT_RESTORED))
      entity.save!
      conn = MemoryEntity.connection
      embedded_at = attrs["embedded_at"] && Time.zone.parse(attrs["embedded_at"])
      conn.update(
        "UPDATE memory_entities SET embedding = UNHEX(#{conn.quote(attrs['embedding_hex'])}), " \
        "embedded_at = #{conn.quote(embedded_at)}, created_at = #{conn.quote(Time.zone.parse(attrs['created_at']))} " \
        "WHERE id = #{entity.id.to_i}"
      )
      entity.reload
    end

    def restore_relations(step)
      step["repointed"].each do |entry|
        MemoryRelation.find(entry["id"]).update!(from_entity_id: entry["from_before"], to_entity_id: entry["to_before"])
      end
      step["destroyed"].each do |attrs|
        if MemoryRelation.exists?(id: attrs["id"]) || MemoryRelation.exists?(attrs.slice("from_entity_id", "to_entity_id", "relation_type"))
          @effects.skipped << "relation ##{attrs['id']} (#{attrs['relation_type']}) exists again"
          next
        end
        MemoryRelation.create!(attrs.slice(*MemoryRelation.column_names))
      end
    end

    # Remove only what the merge added; aliases added since stay.
    def remove_added_aliases(target, aliases)
      added = (alias_list(aliases["aliases_after"]).map(&:downcase) - alias_list(aliases["aliases_before"]).map(&:downcase))
      return if added.empty?

      kept = alias_list(target.aliases).reject { |name| added.include?(name.downcase) }
      target.update!(aliases: kept.join(",").presence)
      @effects.reembed!(target)
    end

    def alias_list(value)
      value.to_s.split(/[,|;]/).map(&:strip).reject(&:blank?)
    end

    def finish(step, restored, target)
      part_of_edges = (step["repointed"] + step["destroyed"]).select { |r| r["relation_type"] == "part_of" }
      cycles = part_of_edges.select do |r|
        from, to = r["from_before"] || r["from_entity_id"], r["to_before"] || r["to_entity_id"]
        RelationSemantics.would_create_cycle?(from, to)
      end
      raise Conflict, [ "Can't undo: restoring the part_of edges would create a cycle" ] if cycles.any?

      ([ restored ] + MemoryEntity.where(id: step["children"].map(&:first)).to_a).each { |entity| ProjectMembership.sync!(entity) }
      [ restored.id, target.id ].each do |entity_id|
        MemoryEntity.where(id: entity_id).update_all(memory_observations_count: MemoryObservation.where(memory_entity_id: entity_id).count)
      end
    rescue ProjectMembership::Collision => e
      raise Conflict, [ "Can't undo: #{e.message}" ]
    end
  end
end
