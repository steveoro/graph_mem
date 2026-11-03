# frozen_string_literal: true

module Llm
  # The projects a prompt's data comes from (agent-CLI PR2), resolved lazily: the Ollama path never
  # asks, so it runs no query. Llm::CloudGate checks it before any cloud call, and it holds the
  # call's (or the scan's) anonymizer session, so every part of one scan shares one mapping.
  #
  #   scope = Llm::Scope.for_entities([widget, project])  # summary evidence, a judge batch
  #   scope = Llm::Scope.for_scan("Gadget Project")        # one scan, all its parts
  #   scope.project_ids # => [7], or nil when some data has no project (unscoped)
  class Scope
    # @param entities [Array<MemoryEntity>] the entities whose text is in the prompt
    # @return [Scope] each entity's project (itself for a Project root, else its project_id);
    #   unscoped if any entity has neither
    def self.for_entities(entities)
      list = Array(entities)
      new(lambda do
        ids = list.map { |entity| entity.project_root? ? entity.id : entity.project_id }
        ids.include?(nil) ? nil : ids.uniq
      end)
    end

    # @param project_name [String] the scanned project's name
    # @return [Scope] the Project root with that name (case-insensitive); unscoped when there is
    #   none yet (a first scan, before reconcile creates it)
    def self.for_scan(project_name)
      new(lambda do
        id = MemoryEntity.where(entity_type: NodeOperationsStrategy::PROJECT_ENTITY_TYPE, project_id: nil, name: project_name.to_s).pick(:id)
        id && [ id ]
      end)
    end

    # @param resolver [#call] returns the project ids, or nil for unscoped data
    def initialize(resolver)
      @resolver = resolver
      @resolved = false
    end

    # @return [Array<Integer>, nil] the projects, resolved on first use; nil when unscoped
    def project_ids
      unless @resolved
        @project_ids = @resolver.call
        @resolved = true
      end
      @project_ids
    end

    # @return [Boolean] some of the data has no project
    def unscoped?
      project_ids.nil?
    end

    # @return [Llm::Anonymizer::Session] this scope's session, built on first cloud use and kept
    #   for the scope's life (one per summary or judge call, one per scan)
    def session
      @session ||= Anonymizer::Session.new(self)
    end

    # @return [String] never the ids or names (scopes must not leak into logs or errors)
    def inspect
      "#<#{self.class.name}>"
    end
  end
end
