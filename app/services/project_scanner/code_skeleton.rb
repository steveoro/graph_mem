# frozen_string_literal: true

class ProjectScanner
  # ProjectScanner's Rails code map (1.75.0): built after the files are discovered, written as the
  # project's skeleton right after the root is reconciled (SkeletonWriter), handed to the model part
  # by part (CodeMapGuide) and asked when a relation's target isn't a local entity. A folder that
  # isn't a Rails project gets RailsCodeMap::Map::EMPTY and none of this runs. Private methods of
  # ProjectScanner; they read and set its instance variables.
  module CodeSkeleton
    private

    def build_code_map!
      @code_map = RailsCodeMap.build(@project_root, reserved_names: code_map_reserved_names,
                                                    keep: ->(path) { @file_filter.allowed?(path) })
    rescue StandardError => e
      # The map is an aid: a scan without it behaves as before.
      @logger.warn "ProjectScanner: Rails code map failed: #{e.class}: #{e.message}"
      @code_map = RailsCodeMap::Map::EMPTY
    end

    def code_map
      @code_map || RailsCodeMap::Map::EMPTY
    end

    # @return [CodeMapGuide, nil] nil when there's no map
    def code_map_guide
      return nil if code_map.empty?

      @code_map_guide ||= CodeMapGuide.new(code_map)
    end

    # The scanned project's own names and every Project root's names and aliases: never a code entry.
    def code_map_reserved_names
      roots = MemoryEntity.where(entity_type: NodeOperationsStrategy::PROJECT_ENTITY_TYPE, project_id: nil).pluck(:name, :aliases)
      ([ @project_name, File.basename(@project_root) ] + @aliases +
        roots.flat_map { |name, aliases| [ name ] + aliases.to_s.split(/[,|;]/) }).map { |name| name.to_s.strip }.compact_blank.uniq
    end

    # Inside the reconcile transaction, right after the root: the skeleton, with its counts merged
    # into the scan's and its entities registered as scanned (local relation targets, and never
    # "missing").
    def write_code_skeleton!
      return if code_map.empty? || @project_entity.nil? || @dry_run

      writer = EmbeddingService.suppress_inline_embeddings do
        SkeletonWriter.new(map: code_map, root: @project_entity, scan_id: @scan_id).call
      end
      merge_skeleton_counts!(writer.counts)
      @created_entity_ids.merge(writer.created_ids)
      writer.entities.each_value { |entity| @entities_by_path[entity.name.downcase] = entity }
      writer.review_items.each { |item| queue_scan_review(item) }
      @errors.concat(writer.errors)
    end

    def merge_skeleton_counts!(counts)
      @code_map_written = counts
      @created_count += counts[:entities_created]
      @updated_count += counts[:entities_updated]
      @observations_created_count += counts[:observations_created] + counts[:facts_superseded]
      @observations_obsoleted_count += counts[:observations_obsoleted]
      @relations_created_count += counts[:relations_created]
    end

    # The skeleton's rows were created without inline embeddings: one backfill after the commit.
    def enqueue_code_map_backfill!
      return unless @code_map_written&.values_at(:entities_created, :entities_updated, :observations_created, :facts_superseded)&.sum.to_i.positive?

      EmbeddingsMaintenanceEnqueuer.enqueue!("backfill")
    rescue StandardError => e
      @logger.warn "ProjectScanner: could not enqueue the embedding backfill: #{e.message}"
    end

    # @return [MemoryEntity, nil] the project's entity of the code entry a relation target means
    def code_map_target(name)
      found = code_map.resolve(name)
      return nil unless found.status == :resolved

      @entities_by_path[found.entry.name.downcase] || MemoryEntity.find_by(name: found.entry.name, project_id: @project_entity&.id)
    end

    # @return [Hash] the result's `code_map`: the map's counters, the guide's and the writer's; {}
    #   when there's no map
    def code_map_counts
      return {} if code_map.empty?

      code_map.counters.merge(code_map_guide&.counts || {}).merge(@code_map_written || {})
    end

    # One numbers-only `[scan]` line (no names: logs stay clean).
    def report_code_map!
      counts = code_map_counts
      @logger.info("[scan] #{JSON.generate(scan_id: @scan_id, code_map: counts)}") if counts.any?
    end
  end
end
