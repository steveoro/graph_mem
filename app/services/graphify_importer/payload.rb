# frozen_string_literal: true

class GraphifyImporter
  # Instance payload-shaping helpers extracted from GraphifyImporter to keep
  # both files under the 500-line rule: reference annotations on tree
  # children, node observations, and the import meta line. Included (not
  # extended) — these run on the importer instance against
  # @edges/@entity_info/@data.
  module Payload
    # Every non-containment payload edge targeting `id`, as the resolver
    # needs them: the referencing entity's name+type plus the edge type —
    # the CANONICAL type from EDGE_RELATION_MAPPINGS, since the stored-edge
    # match compares against the relation_type actually written
    # (`imports_from` stores `depends_on`; matching on the raw payload
    # name would miss). Unmapped kinds keep their raw name — they never
    # produce a stored edge anyway.
    def reference_referrers(id)
      Array(referrers_index[id]).filter_map do |edge|
        info = @entity_info[edge["source"]]
        next unless info

        kind = edge["relation"].to_s
        { "name" => info[:name], "entity_type" => info[:entity_type],
          "relation" => EDGE_RELATION_MAPPINGS[kind] || kind }
      end.uniq { |r| [ r["name"], r["entity_type"], r["relation"] ] }
    end

    # Non-containment edges grouped by target — memoized once: scanning
    # the whole edge list per reference node is O(refs × edges) on big
    # payloads.
    def referrers_index
      @referrers_index ||=
        @edges.reject { |edge| CONTAINMENT_RELATIONS.include?(edge["relation"].to_s) }
              .group_by { |edge| edge["target"] }
    end

    # Node observations pass through (e.g. extractor "Superclass:" lines),
    # then provenance when the node declares a source file; reference-only
    # nodes carry no file → a stub never claims a class.
    def entity_observations(node)
      # Passthrough observations keep their content but NEVER their own
      # source/confidence — otherwise an uploaded graph.json could stamp
      # "official verified" trust onto arbitrary claims.
      obs = Array(node["observations"]).filter_map do |o|
        next unless o.is_a?(Hash) && o["content"].present?

        # Clamp numeric confidence to [0,1]; missing/non-numeric stays NULL
        # (the ranker reads NULL as neutral 0.5, not 0.0).
        confidence = Float(o["confidence"], exception: false)&.clamp(0.0, 1.0)
        o.merge("source" => producer_name, "confidence" => confidence)
      end
      file = node["source_file"].to_s
      return obs if file.blank?

      obs + [ provenance_observation("Defined at #{[ file, node['source_location'].to_s.presence ].compact.join(':')}") ]
    end

    def provenance_observation(content)
      {
        "content" => content,
        "source" => producer_name,
        "confidence" => 1.0,
        "tags" => [ producer_name, "provenance" ]
      }
    end

    def graph_meta_line
      meta = @data["graph"] || {}
      parts = [ "Imported from graph.json" ]
      parts << "graphify #{meta['graphify_version']}" if meta["graphify_version"]
      parts << "schema #{meta['schema_version']}" if meta["schema_version"]
      parts << "commit #{@data['built_at_commit']}" if @data["built_at_commit"]
      parts.join(", ")
    end
  end
end
