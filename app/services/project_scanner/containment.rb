# frozen_string_literal: true

class ProjectScanner
  # Containment for the scan's own entities (private methods of ProjectScanner; they read its
  # instance variables). Every entity a scan reconciles is stamped into the scanned project, so it
  # must also hang on that project's part_of tree: after the relations pass, each reconciled entity
  # still without a part_of parent gets one to the project root, as SkeletonWriter#ensure_parent
  # does for the code map. A parent the model emitted is kept.
  #
  # The edge is marked like the skeleton writer's (`properties.source`, `properties.scan_id`), with
  # the CONTAINMENT_PHASE source, so a tool can tell a scanner-made containment edge from a
  # model-emitted one (GraphMem::ScanProfile::Metrics counts entities that have nothing else).
  # The entity is already stamped with the root, so no membership sync (and no lock) is needed.
  module Containment
    CONTAINMENT_PHASE = "containment"

    # @param source [String, nil] a relation's properties["source"]
    # @return [Boolean] true for a containment edge a scan added (not one the model emitted)
    def self.containment_source?(source)
      source.to_s.start_with?("project_scan:") && source.to_s.end_with?(":#{CONTAINMENT_PHASE}")
    end

    private

    # @param entities [Array<MemoryEntity>] the reconciled entities
    def attach_to_root!(entities)
      return if @dry_run || @project_entity.nil?

      entities.uniq(&:id).each do |entity|
        next if entity.id == @project_entity.id || entity.entity_type == NodeOperationsStrategy::PROJECT_ENTITY_TYPE
        next if MemoryRelation.exists?(from_entity_id: entity.id, relation_type: "part_of")

        MemoryRelation.create!(from_entity_id: entity.id, to_entity_id: @project_entity.id, relation_type: "part_of",
                               properties: { source: scan_source(CONTAINMENT_PHASE), scan_id: @scan_id })
        @relations_created_count += 1
      rescue ActiveRecord::RecordInvalid => e
        @errors << "Failed to attach #{entity.name} to the project root: #{e.message}"
      end
    end
  end
end
