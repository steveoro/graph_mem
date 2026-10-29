# frozen_string_literal: true

class GraphSearch
  # The operator/guest Search page's query (UI-3). Turns the page's URL parameters into one
  # GraphSearch.call with the tool's own paging and filters, ignoring agents' context, so page N
  # here is page N of the `search` tool for the same arguments. Adds what the page shows per row
  # (snippets, project name, relation count) with a fixed number of queries and no embedding call.
  #
  #   result = GraphSearch::Page.call({ "q" => "SynthWidget", "types" => [ "Component" ] })
  #   result.rows.first.entity # => MemoryEntity
  #   result.error             # => nil, or the validation message to show (status 422)
  class Page
    MODES = %w[auto text semantic exact].freeze
    # The old page's ?strategy= values still work.
    LEGACY_STRATEGIES = { "text" => "text", "vector" => "semantic" }.freeze
    # match[] value => the search tool's flag
    MATCH_FLAGS = { "name" => :search_in_name, "aliases" => :search_in_aliases, "type" => :search_in_type,
                    "observations" => :search_in_observations }.freeze
    PER_PAGE = 20
    # Bounds for this guest-reachable page: ranks are fetched as offset + per_page, so a huge
    # page would turn into huge LIMITs on every channel (50 pages = 1,000 ranks).
    MAX_PAGE = 50
    MAX_QUERY_LENGTH = 500
    # Exact mode loads at most this many LIKE candidates before its exact Ruby check.
    EXACT_SCAN_LIMIT = 1_000
    # The columns a result row shows (never the embedding).
    ROW_COLUMNS = %i[id name entity_type aliases description project_id memory_observations_count created_at updated_at].freeze
    TYPE_OPTIONS_LIMIT = 50

    Row = Struct.new(:entity, :relevance_score, :matched_fields, :snippets, :project_name, :relation_count,
                     keyword_init: true) do
      def id = entity.id
    end

    Result = Struct.new(:query, :mode, :page, :per_page, :rows, :filters, :error, :semantic_available,
                        keyword_init: true) do
      def next_page? = rows.size == per_page && page < MAX_PAGE
      def searched? = query.present?
    end

    # @param params [Hash, ActionController::Parameters] q, mode, strategy, project_id, types[],
    #   match[], perspective, occurred_after, occurred_before, as_of, include_obsolete, page
    # @param per_page [Integer] 1-100
    # @return [Result]
    def self.call(params, per_page: PER_PAGE)
      new(params.to_h.with_indifferent_access, per_page).call
    end

    # @return [Array<Array(String, Integer)>] Project roots as [name, id], by name
    def self.project_options
      MemoryEntity.where(entity_type: NodeOperationsStrategy::PROJECT_ENTITY_TYPE, project_id: nil).order(:name).pluck(:name, :id)
    end

    # @return [Array<String>] up to TYPE_OPTIONS_LIMIT entity types, alphabetically
    def self.type_options
      MemoryEntity.distinct.order(:entity_type).limit(TYPE_OPTIONS_LIMIT).pluck(:entity_type)
    end

    def initialize(params, per_page)
      @params = params
      @per_page = per_page
      @query = params[:q].to_s.strip
      @semantic_available = EmbeddingService.vector_enabled?
      @mode = resolve_mode
      @page = [ params[:page].to_i, 1 ].max
      @filters = normalized_filters
    end

    # @return [Result]
    def call
      rows, error = @query.blank? ? [ [], nil ] : search
      Result.new(query: @query, mode: @mode, page: @page, per_page: @per_page, rows: rows, filters: @filters,
                 error: error, semantic_available: @semantic_available)
    end

    private

    def resolve_mode
      mode = @params[:mode].presence || LEGACY_STRATEGIES[@params[:strategy]]
      mode = "auto" unless MODES.include?(mode)
      mode == "semantic" && !@semantic_available ? "auto" : mode
    end

    # The page's filters with blanks dropped: what the form and links carry.
    def normalized_filters
      match = Array(@params[:match]).compact_blank & MATCH_FLAGS.keys if @params.key?(:match)
      {
        project_id: @params[:project_id].presence,
        types: Array(@params[:types]).map(&:to_s).compact_blank,
        match: match,
        perspective: @params[:perspective].presence,
        occurred_after: @params[:occurred_after].presence,
        occurred_before: @params[:occurred_before].presence,
        as_of: @params[:as_of].presence,
        include_obsolete: ActiveModel::Type::Boolean.new.cast(@params[:include_obsolete]) == true
      }
    end

    def search
      validate_bounds!
      hits = @mode == "exact" ? exact_hits : ranked_hits
      [ build_rows(hits), nil ]
    rescue GraphMem::InvalidArgumentsError => e
      [ [], e.message ]
    end

    def validate_bounds!
      raise GraphMem::InvalidArgumentsError, "page must be between 1 and #{MAX_PAGE}." if @page > MAX_PAGE
      return if @query.length <= MAX_QUERY_LENGTH

      raise GraphMem::InvalidArgumentsError, "The query must be at most #{MAX_QUERY_LENGTH} characters."
    end

    # match[] absent = every field on (the tool's defaults); present = exactly the listed fields.
    def search_flags
      return {} if @filters[:match].nil?

      MATCH_FLAGS.to_h { |value, flag| [ flag, @filters[:match].include?(value) ] }
    end

    # @return [Array<Hash>] `{ entity_id:, relevance_score:, matched_fields: }` in rank order
    def ranked_hits
      result = GraphSearch.call(
        query: @query, page: @page, per_page: @per_page,
        project_id: @filters[:project_id], entity_types: @filters[:types].presence, **search_flags,
        perspective: @filters[:perspective], occurred_after: @filters[:occurred_after],
        occurred_before: @filters[:occurred_before], as_of: @filters[:as_of],
        context_scope: nil, ambient_context: false, semantic: @mode != "text", text: @mode != "semantic"
      )
      result[:results]
    end

    # Name equal to the query, or one whole alias equal to it, within the filter's entities.
    def exact_hits
      filter = SearchFilter.build(project_id: @filters[:project_id], entity_types: @filters[:types].presence)
      candidates = filter.entity_scope || MemoryEntity.all
      named = name_hits(candidates)
      aliased = alias_hits(candidates).reject { |entity| named.any? { |hit| hit.id == entity.id } }
      matches = (named.map { |entity| [ entity, "name" ] } + aliased.map { |entity| [ entity, "aliases" ] })
                .sort_by { |entity, _field| [ entity.name.to_s.downcase, entity.id ] }
      matches.drop((@page - 1) * @per_page).first(@per_page)
             .map { |entity, field| { entity_id: entity.id, relevance_score: nil, matched_fields: [ field ], entity: entity } }
    end

    # Its own query, so no number of alias candidates can push an exact name out of the scan. The
    # column's collation ignores case; the Ruby check keeps the match exact. At most one row per
    # project scope (the unique key on project_scope and name).
    def name_hits(candidates)
      candidates.where(name: @query).select(*ROW_COLUMNS).order(:name, :id)
                .select { |entity| entity.name.to_s.casecmp?(@query) }
    end

    # Entities with one whole alias equal to the query, from at most EXACT_SCAN_LIMIT LIKE candidates.
    def alias_hits(candidates)
      needle = @query.downcase
      lower_aliases = Arel::Nodes::NamedFunction.new("LOWER", [ MemoryEntity.arel_table[:aliases] ])
      # The query is escaped for LIKE: % and _ in it are literal, not wildcards.
      like = "%#{MemoryEntity.sanitize_sql_like(needle)}%"
      candidates.where(lower_aliases.matches(like)).select(*ROW_COLUMNS).order(:name, :id).limit(EXACT_SCAN_LIMIT)
                .select { |entity| alias_list(entity).include?(needle) }
    end

    # Aliases are stored as one string separated by commas or pipes; each piece is a whole alias.
    def alias_list(entity)
      entity.aliases.to_s.downcase.split(/\s*[,|]\s*/).compact_blank
    end

    def build_rows(hits)
      ids = hits.map { |hit| hit[:entity_id] }
      return [] if ids.empty?

      entities = hits.all? { |hit| hit[:entity] } ? hits.to_h { |hit| [ hit[:entity_id], hit[:entity] ] } : MemoryEntity.where(id: ids).index_by(&:id)
      snippets = Snippets.call(ids, query: @query, perspective: @filters[:perspective], include_obsolete: @filters[:include_obsolete])
      project_names = MemoryEntity.where(id: entities.values.filter_map(&:project_id).uniq).pluck(:id, :name).to_h
      counts = relation_counts(ids)

      hits.filter_map do |hit|
        entity = entities[hit[:entity_id]]
        next unless entity

        Row.new(entity: entity, relevance_score: hit[:relevance_score], matched_fields: hit[:matched_fields],
                snippets: snippets.fetch(entity.id, []), project_name: project_names[entity.project_id],
                relation_count: counts[entity.id])
      end
    end

    def relation_counts(ids)
      from = MemoryRelation.where(from_entity_id: ids).group(:from_entity_id).count
      to = MemoryRelation.where(to_entity_id: ids).group(:to_entity_id).count
      ids.index_with { |id| from.fetch(id, 0) + to.fetch(id, 0) }
    end
  end
end
