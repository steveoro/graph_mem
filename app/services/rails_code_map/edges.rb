# frozen_string_literal: true

class RailsCodeMap
  # The relations of a Rails code map (1.75.0), between its own entries only:
  #
  # - CODE_RELATIONS the extractor proved (inherits, belongs_to, has_many, has_one, mixes_in);
  #   AMBIGUOUS edges and edges to constants outside the map are skipped;
  # - config/routes.rb `routes_to` each controller a route names. Engine routes name controllers
  #   without the engine's namespace, so a controller is looked up as written, then inside each
  #   `isolate_namespace` (lib/**/engine.rb), then as the one Controller entry with that short name;
  # - each View or Layout entry `relates_to` the controller or mailer that renders it
  #   (Views.owner_names), from the constant's side.
  #
  # It also returns each controller's "Routes: …" fact.
  #
  #   edges, route_facts = RailsCodeMap::Edges.build(graph, entries, namespaces: ["GogglesDb"])
  #   edges.first       # => #<data Edge from="GogglesDb::Badge", to="GogglesDb::Swimmer", relation="belongs_to">
  #   route_facts.first # => ["GogglesDb::SwimmersController", "Routes: GET /swimmers, POST /swimmers"]
  module Edges
    CODE_RELATIONS = %w[inherits belongs_to has_many has_one mixes_in].freeze
    ROUTES_RELATION = "routes_to"
    VIEW_RELATION = "relates_to"
    # The most routes a controller's fact lists.
    MAX_ROUTES = 20
    ENGINE_FILES = "lib/**/engine.rb"
    ISOLATE_NAMESPACE = /^\s*isolate_namespace[\s(]+(?:::)?([A-Z]\w*(?:::[A-Z]\w*)*)/

    module_function

    # @param graph [Hash] RailsAstExtractor#extract's graph
    # @param entries [Array<Entry>] the map's entries
    # @param namespaces [Array<String>] the engines' isolated namespaces
    # @return [Array(Array<Edge>, Hash{String => String})] the edges, and each controller's routes fact
    def build(graph, entries, namespaces: [])
      index = entries.index_by { |entry| RailsCodeMap.lookup_key(entry.name) }
      labels = Array(graph["nodes"]).to_h { |node| [ node["id"], node["label"].to_s ] }
      edges = code_edges(graph, labels, index)
      routes, route_facts = route_edges(graph, labels, index, entries, namespaces)
      (edges + routes + view_edges(entries, index)).uniq.then { |all| [ all, route_facts ] }
    end

    # @param root [String] the project folder
    # @param keep [#call, nil]
    # @return [Array<String>] the namespaces `isolate_namespace` names in the engine files
    def namespaces(root, keep: nil)
      Dir.glob(ENGINE_FILES, base: root).sort.flat_map do |rel|
        path = File.join(root, rel)
        next [] unless File.file?(path) && !File.symlink?(path) && (keep.nil? || keep.call(path)) && File.size(path) < 100_000

        File.read(path, encoding: "UTF-8").scrub.scan(ISOLATE_NAMESPACE).flatten
      end.uniq
    end

    def code_edges(graph, labels, index)
      Array(graph["links"]).filter_map do |link|
        next unless CODE_RELATIONS.include?(link["relation"]) && link["confidence"] != "AMBIGUOUS"

        from = index[RailsCodeMap.lookup_key(labels[link["source"]])]
        to = index[RailsCodeMap.lookup_key(labels[link["target"]])]
        Edge.new(from: from.name, to: to.name, relation: link["relation"]) if from && to && from != to
      end
    end

    def route_edges(graph, labels, index, entries, namespaces)
      routes_file = index[RailsCodeMap.lookup_key(RailsCodeMap::ROUTES_FILE)]
      controllers = entries.select { |entry| entry.type == "Controller" }
                           .group_by { |entry| RailsCodeMap.lookup_key(entry.name.split("::").last) }
      paths = Hash.new { |hash, name| hash[name] = [] }
      Array(graph["links"]).each do |link|
        next unless link["relation"] == ROUTES_RELATION

        controller = controller_entry(labels[link["target"]].to_s.split("#").first.to_s, index, controllers, namespaces)
        paths[controller.name] |= [ labels[link["source"]] ] if controller
      end

      edges = routes_file ? paths.keys.map { |name| Edge.new(from: routes_file.name, to: name, relation: ROUTES_RELATION) } : []
      [ edges, paths.transform_values { |routes| routes_fact(routes) } ]
    end

    def controller_entry(const, index, controllers, namespaces)
      return nil if const.blank?

      index[RailsCodeMap.lookup_key(const)] ||
        namespaces.lazy.filter_map { |namespace| index[RailsCodeMap.lookup_key("#{namespace}::#{const}")] }.first ||
        controllers.fetch(RailsCodeMap.lookup_key(const.split("::").last), []).then { |found| found.first if found.size == 1 }
    end

    def routes_fact(routes)
      listed = routes.first(MAX_ROUTES).join(", ")
      listed += " (and #{routes.size - MAX_ROUTES} more)" if routes.size > MAX_ROUTES
      "Routes: #{listed}"
    end

    def view_edges(entries, index)
      entries.select { |entry| %w[View Layout].include?(entry.type) }.filter_map do |view|
        owner = Views.owner_names(view.name).lazy.filter_map { |name| index[RailsCodeMap.lookup_key(name)] }.first
        Edge.new(from: owner.name, to: view.name, relation: VIEW_RELATION) if owner
      end
    end
    private_class_method :code_edges, :route_edges, :controller_entry, :routes_fact, :view_edges
  end
end
