# frozen_string_literal: true

module Api
  module V1
    # The canvas's read endpoint (Explore, and Search's "Show as graph"); guest-readable. Every
    # branch returns at most MAX_NODES entities and only the relations among them, with a fixed
    # number of queries: the nodes, one grouped count of active observations, the relations.
    # When the cap applies the body also carries "truncated": true and "total": N.
    class GraphDataController < BaseController
      # "Show as graph" (UI-3) sends one page of search results; UI-4b's Explore reuses it.
      MAX_IDS = EntityIdList::MAX
      IDS_ERROR = "ids must be 1 to #{MAX_IDS} comma-separated entity ids.".freeze
      MAX_NODES = 2_000
      DEPTHS = [ 1, 2 ].freeze
      DEPTH_ERROR = "depth must be 1 or 2."
      PROJECT_ERROR = "project_id must be a project root's id."
      NODE_COLUMNS = %i[id name entity_type aliases memory_observations_count].freeze

      # GET /api/v1/graph_data(?ids=1,2,3 | ?project_id= | ?scoped_entity_id= | ?entity_id=[&depth=1|2] | ?root_only=true)
      def index
        return render_error(DEPTH_ERROR) if params.key?(:depth) && depth.nil?

        if params.key?(:ids)
          render_ids_graph(params[:ids])
        elsif params[:project_id].present?
          render_project_graph(params[:project_id])
        elsif params[:scoped_entity_id].present?
          render_scoped_subgraph(params[:scoped_entity_id])
        elsif params[:entity_id].present?
          render_subgraph(params[:entity_id])
        elsif params[:root_only] == "true"
          render_root_graph
        else
          render_full_graph
        end
      end

      private

      # @return [Integer, nil] 1 or 2 (1 when absent), nil when invalid
      def depth
        return 1 unless params.key?(:depth)

        value = params[:depth].to_s
        value.to_i if value.match?(/\A\d\z/) && DEPTHS.include?(value.to_i)
      end

      # The given entities and the relations among them only (no hop expansion); unknown ids
      # are skipped. 422 unless ids is 1 to MAX_IDS positive integers, comma-separated.
      def render_ids_graph(raw)
        ids = EntityIdList.parse(raw, max: MAX_IDS)
        return render_error(IDS_ERROR) unless ids

        nodes = load_nodes(ids)
        render_graph_data(nodes, { focus_entity_ids: nodes.map { |node| node.id.to_s } })
      end

      def render_full_graph
        ids = MemoryEntity.order(:id).limit(MAX_NODES + 1).pluck(:id)
        total = MemoryEntity.count if ids.size > MAX_NODES
        render_capped(ids, total: total)
      end

      def render_root_graph
        ids = MemoryEntity.where(entity_type: [ NodeOperationsStrategy::PROJECT_ENTITY_TYPE, nil ]).order(:id).limit(MAX_NODES + 1).pluck(:id)
        render_capped(ids)
      end

      # A project root and its part_of subtree (ProjectSubtree's walk, bounded by MAX_NODES).
      def render_project_graph(raw)
        id = EntityIdList.id(raw.to_s)
        root = id && MemoryEntity.find_by(id: id, entity_type: NodeOperationsStrategy::PROJECT_ENTITY_TYPE, project_id: nil)
        return render_error(PROJECT_ERROR) unless root

        subtree = ProjectSubtree.resolve(root.id, max_entities: MAX_NODES)
        total = MemoryEntity.where(project_id: root.id).count + 1 if subtree.truncated?
        render_capped(subtree.entity_ids, total: total, truncated: subtree.truncated?, options: { focus_entity_id: root.id.to_s })
      end

      # An entity and its direct part_of children.
      def render_scoped_subgraph(scoped_entity_id)
        root_entity = MemoryEntity.find(scoped_entity_id)
        child_ids = MemoryRelation.where(relation_type: "part_of", to_entity_id: root_entity.id).order(:from_entity_id).pluck(:from_entity_id)
        render_capped(([ root_entity.id ] + child_ids).uniq, options: { focus_entity_id: scoped_entity_id }, keep: root_entity.id)
      end

      # An entity and its neighbours, one or two hops out.
      def render_subgraph(entity_id)
        focus = MemoryEntity.find(entity_id)
        ids = [ focus.id ]
        frontier = ids
        depth.times do
          hop = MemoryRelation.where(from_entity_id: frontier).pluck(:to_entity_id) +
                MemoryRelation.where(to_entity_id: frontier).pluck(:from_entity_id)
          frontier = hop.uniq - ids
          ids += frontier.sort
        end
        render_capped(ids, options: { focus_entity_id: entity_id }, keep: focus.id)
      end

      # Keeps `keep` (the focus) and the lowest ids up to MAX_NODES.
      def render_capped(ids, total: nil, truncated: nil, options: {}, keep: nil)
        truncated = ids.size > MAX_NODES if truncated.nil?
        capped = ids.sort
        capped = (keep ? [ keep ] + (capped - [ keep ]) : capped).first(MAX_NODES) if truncated
        extra = truncated ? { truncated: true, total: total || ids.size } : {}
        render_graph_data(load_nodes(capped), options, **extra)
      end

      def load_nodes(ids)
        MemoryEntity.where(id: ids).select(*NODE_COLUMNS).order(:id).to_a
      end

      def render_graph_data(entities, options = {}, **extra)
        ids = entities.map(&:id)
        counts = MemoryObservation.active.where(memory_entity_id: ids).group(:memory_entity_id).count
        names = entities.to_h { |entity| [ entity.id, entity.name ] }
        relations = MemoryRelation.where(from_entity_id: ids, to_entity_id: ids).order(:id)

        nodes = entities.map { |entity| node_element(entity, counts.fetch(entity.id, 0), options) }
        edges = relations.map { |relation| edge_element(relation, names) }

        render json: { elements: nodes + edges, options: options, **extra }
      end

      def node_element(entity, observation_count, options)
        {
          group: "nodes",
          data: {
            id: entity.id.to_s,
            label: entity.name,
            type: entity.entity_type,
            aliases: entity.aliases,
            memory_observations_count: observation_count,
            is_focus: options[:focus_entity_id] == entity.id.to_s
          }
        }
      end

      def edge_element(relation, names)
        {
          group: "edges",
          data: {
            id: "r#{relation.id}",
            relation_id: relation.id,
            source: relation.from_entity_id.to_s,
            target: relation.to_entity_id.to_s,
            label: relation.relation_type,
            weight: relation.weight,
            confidence: relation.confidence,
            properties: relation.properties,
            from_entity_name: names[relation.from_entity_id],
            to_entity_name: names[relation.to_entity_id]
          }
        }
      end
    end
  end
end
