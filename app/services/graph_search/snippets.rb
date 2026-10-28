# frozen_string_literal: true

class GraphSearch
  # Up to two observation snippets per entity for one page of Search results, from ONE query
  # and with no embedding call: observations of the page's entities whose content contains any
  # query token, best token overlap first, then trust.
  #
  #   GraphSearch::Snippets.call([ 7, 9 ], query: "synth tiles")
  #   # => { 7 => [<MemoryObservation>, <MemoryObservation>], 9 => [...] }
  class Snippets
    PER_ENTITY = 2

    # @param entity_ids [Array<Integer>] the page's entities
    # @param query [String] the search query (a temporal phrase in it is ignored)
    # @param perspective [String, nil] only observations of this perspective
    # @param include_obsolete [Boolean] also obsolete and superseded observations
    # @return [Hash{Integer => Array<MemoryObservation>}]
    def self.call(entity_ids, query:, perspective: nil, include_obsolete: false)
      tokens = tokens_for(query)
      return {} if entity_ids.empty? || tokens.empty?

      content = Arel::Nodes::NamedFunction.new("LOWER", [ MemoryObservation.arel_table[:content] ])
      observations = MemoryObservation.where(memory_entity_id: entity_ids)
                                      .where(tokens.map { |token| content.matches("%#{token}%") }.reduce(:or))
      observations = observations.active unless include_obsolete
      observations = observations.where(perspective: perspective) if perspective.present?

      observations.to_a.group_by(&:memory_entity_id).transform_values do |list|
        list.sort_by { |observation| [ -QueryTokenizer.overlap_score(tokens, observation.content), -observation.trust_score.to_f, observation.id ] }
            .first(PER_ENTITY)
      end
    end

    # @return [Array<String>] the query's search tokens, temporal phrase removed
    def self.tokens_for(query)
      QueryTokenizer.tokenize(TemporalQueryParser.apply(query.to_s).effective_query)
    end
  end
end
