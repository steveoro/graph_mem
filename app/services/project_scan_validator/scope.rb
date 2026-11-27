# frozen_string_literal: true

class ProjectScanValidator
  # Which entities a validation pass covers, and which of their facts (private methods of
  # ProjectScanValidator; they read its instance variables).
  #
  # - The project's part_of subtree (ProjectSubtree), less the entities this scan created and the
  #   root: every fact of theirs is checked, as before.
  # - Dream State R1b: the global entities of a dependency-like type the project depends_on
  #   (ProjectScanner::GlobalDependencies.entity_ids). Such a node is shared, so only the facts this
  #   project's scans wrote onto it (source `project_scan:<scan id>:dependency:<project id>`) are
  #   checked, and its relations are not: another project's facts and edges, and the manual ones,
  #   are never moved, obsoleted or queued by this project's validation.
  module Scope
    private

    def compute_entity_ids!
      ids = ProjectSubtree.resolve(@project_entity.id).entity_ids - @created_entity_ids.to_a - [ @project_entity.id ]
      @pending_entity_ids = (ids + dependency_entity_ids).uniq
      @processed_entity_ids = []
    end

    # @return [Array<Integer>] the project's global dependencies (read once per validator)
    def dependency_entity_ids
      @dependency_entity_ids ||= ProjectScanner::GlobalDependencies.entity_ids(@project_entity)
    end

    # @return [Boolean] a global dependency of the project (not a member of its subtree)
    def global_dependency?(entity)
      entity.project_id.nil? && dependency_entity_ids.include?(entity.id)
    end

    # @return [Boolean] this validation may judge the observation
    def covered_observation?(entity, observation)
      !global_dependency?(entity) || ProjectScanner::GlobalDependencies.fact_source?(observation.source, @project_entity.id)
    end
  end
end
