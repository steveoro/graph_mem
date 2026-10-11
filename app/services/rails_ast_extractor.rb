# frozen_string_literal: true

require "prism"
require "pathname"
require "active_support"
require "active_support/core_ext"

# Emits a graphify-compatible graph.json for a Rails application's own code:
# classes/modules, their `def` methods, and the Rails DSL facts static
# analysis can prove — associations, scopes, enum accessors, delegation,
# mixin usage, and routes.
#
# Design decisions (deliberately conservative — a fact that is only probably
# true is worse than a missing fact):
# * Deterministic only: pure Prism AST walk, no runtime loading, no LLM.
# * Two passes: every file is indexed (class/module/def declarations) before
#   any edge is resolved, so an association in file A resolves to a class
#   declared in file B regardless of scan order.
# * Association/mixin targets that cannot be resolved to a scanned constant
#   are emitted anyway as best-guess qualified names (unresolved references
#   are first-class: they merge into a real entity when that repo is
#   imported, or stay honest dangling references until then).
# * A name resolving to >1 distinct qualified constant produces an
#   AMBIGUOUS edge — the importer withholds those into scan_review.
# * Every emitted edge carries properties.provenance = "RAILS_DSL" so the
#   review/scan UI can tell extracted facts apart.
class RailsAstExtractor
  PRODUCER = "rails_ast_extractor"
  SCANNED_DIRS = %w[app/models app/controllers].freeze
  ROUTES_FILE = "config/routes.rb"
  RUBY_EXT = ".rb"
  ASSOCIATION_RELATIONS = {
    "belongs_to" => "belongs_to",
    "has_many" => "has_many",
    "has_one" => "has_one",
    "has_and_belongs_to_many" => "has_many"
  }.freeze
  MIXIN_MACROS = %w[include extend prepend].freeze
  # action => [verb, suffix] pairs; update expands to PATCH+PUT.
  REST_ACTIONS = {
    "index" => [ [ "GET", ":base" ] ],
    "new" => [ [ "GET", ":base/new" ] ],
    "create" => [ [ "POST", ":base" ] ],
    "show" => [ [ "GET", ":base/:id" ] ],
    "edit" => [ [ "GET", ":base/:id/edit" ] ],
    "update" => [ [ "PATCH", ":base/:id" ], [ "PUT", ":base/:id" ] ],
    "destroy" => [ [ "DELETE", ":base/:id" ] ]
  }.freeze
  HTTP_VERBS = %w[get post put patch delete options head match].freeze

  def self.extract(repo_path, project_name: File.basename(File.expand_path(repo_path)))
    new(repo_path, project_name: project_name).extract
  end

  def initialize(repo_path, project_name:)
    @repo = Pathname.new(File.expand_path(repo_path))
    @project_name = project_name
    @nodes = []
    @links = []
    @node_ids = {} # "Type:label" => node id
    @const_decls = Hash.new { |h, k| h[k] = [] }   # qualified name => [{file:, line:}]
    @basename_index = Hash.new { |h, k| h[k] = [] } # short name => qualified names
    @method_decls = {}                             # "C#m"/"C.m" => {file:, line:}
    @assoc_targets = Hash.new { |h, k| h[k] = {} } # owner qualified => {assoc => class_name}
    @nodes_by_id = {}                              # id => node (O(1) upgrade lookups)
    @parse_cache = {}                              # path => ProgramNode|nil
    @stats = Hash.new(0)
  end

  def extract
    files = ruby_files
    # Pass 1: index every declaration so pass 2 resolves order-independently.
    files.each { |f| index_file(f) }
    files.each { |f| emit_file(f) }
    scan_routes
    {
      "producer" => PRODUCER,
      "schema_version" => "1.0",
      "directed" => true,
      "graph" => { "built_by" => PRODUCER, "project" => @project_name },
      "nodes" => @nodes,
      "links" => @links,
      "stats" => @stats
    }
  end

  private

  def ruby_files
    repo_root = File.realpath(@repo.to_s)
    SCANNED_DIRS.flat_map do |dir|
      base = @repo.join(dir)
      next [] unless base.directory?

      Dir[base.join("**/*#{RUBY_EXT}")].sort.select do |file|
        # Only real files inside the repo root: a symlinked file (or a
        # symlinked directory) pointing outside must not leak another
        # tree's class/method names into the graph.
        File.file?(file) && File.realpath(file).start_with?("#{repo_root}/")
      end
    end
  end

  MAX_FILE_BYTES = 2 * 1024 * 1024 # skip pathological files

  # Memoized per path: pass 1 and pass 2 share the parse, so failures are
  # counted once and each file is parsed once.
  def parse_ok(path)
    return @parse_cache[path] if @parse_cache.key?(path)

    @parse_cache[path] =
      if File.size(path) > MAX_FILE_BYTES
        @stats[:files_too_large] += 1
        nil
      elsif (parsed = Prism.parse_file(path)).success?
        parsed.value
      else
        @stats[:files_parse_failed] += 1
        nil
      end
  end

  # ------------------------------------------------------------------
  # Pass 1: index class/module/def declarations.
  # ------------------------------------------------------------------
  def index_file(path)
    program = parse_ok(path)
    return unless program

    walk_index(Array(program.statements&.body), const_prefix: [], rel: relative(path))
  end

  def walk_index(statements, const_prefix:, rel:)
    statements.each do |stmt|
      case stmt
      when Prism::ClassNode, Prism::ModuleNode
        name = const_full_name(stmt.constant_path)
        next if name.blank?

        qualified = (const_prefix + name.split("::")).join("::")
        @const_decls[qualified] << { file: rel, line: line(stmt) }
        @basename_index[qualified.split("::").last] |= [ qualified ]
        walk_index(Array(stmt.body&.body), const_prefix: const_prefix + name.split("::"), rel: rel)
      when Prism::DefNode
        sep = stmt.receiver ? "." : "#"
        @method_decls["#{const_prefix.join('::')}#{sep}#{stmt.name}"] =
          { file: rel, line: line(stmt) }
      when Prism::CallNode
        walk_index(Array(stmt.block&.body&.body), const_prefix: const_prefix, rel: rel) if stmt.block
      else
        walk_index(Array(stmt.compact_child_nodes), const_prefix: const_prefix, rel: rel) if container_like?(stmt)
      end
    end
  end

  # ------------------------------------------------------------------
  # Pass 2: emit nodes + edges.
  # ------------------------------------------------------------------
  def emit_file(path)
    program = parse_ok(path)
    return unless program

    rel = relative(path)
    file_id = add_node(File.basename(path), source_file: rel, entity_type: "File")
    walk_emit(Array(program.statements&.body), file_id: file_id, rel: rel, const_prefix: [])
  end

  def walk_emit(statements, file_id:, rel:, const_prefix:)
    statements.each do |stmt|
      case stmt
      when Prism::ClassNode, Prism::ModuleNode
        name = const_full_name(stmt.constant_path)
        next if name.blank?

        qualified = (const_prefix + name.split("::")).join("::")
        node_id = add_node(qualified, source_file: rel, source_location: line(stmt),
                           entity_type: "Class", extra_obs: class_observations(stmt))
        add_containment(parent_for(file_id, const_prefix), node_id)
        walk_emit(Array(stmt.body&.body), file_id: node_id, rel: rel,
                  const_prefix: const_prefix + name.split("::"))
      when Prism::DefNode
        sep = stmt.receiver ? "." : "#"
        node_id = add_node("#{const_prefix.join('::')}#{sep}#{stmt.name}",
                           source_file: rel, source_location: line(stmt),
                           entity_type: "Method")
        add_containment(parent_for(file_id, const_prefix), node_id)
      when Prism::CallNode
        handle_dsl_call(stmt, const_prefix: const_prefix, rel: rel)
        walk_emit(Array(stmt.block&.body&.body), file_id: file_id, rel: rel,
                  const_prefix: const_prefix) if stmt.block
      else
        # Statements nested in begin/if bodies still contribute definitions.
        walk_emit(Array(stmt.compact_child_nodes), file_id: file_id, rel: rel,
                  const_prefix: const_prefix) if container_like?(stmt)
      end
    end
  end

  def container_like?(node)
    node.is_a?(Prism::BeginNode) || node.is_a?(Prism::IfNode) ||
      node.is_a?(Prism::UnlessNode) || node.is_a?(Prism::CaseNode)
  end

  def parent_for(file_id, const_prefix)
    return file_id if const_prefix.empty?

    add_node(const_prefix.join("::"), source_file: nil, entity_type: "Class")
  end

  # ------------------------------------------------------------------
  # DSL handling
  # ------------------------------------------------------------------
  def handle_dsl_call(call, const_prefix:, rel:)
    return if const_prefix.empty?

    owner_qualified = const_prefix.join("::")
    owner = add_node(owner_qualified, source_file: nil, entity_type: "Class")

    case call.name.to_s
    when *ASSOCIATION_RELATIONS.keys
      emit_association(call, owner, owner_qualified, const_prefix, rel)
    when *MIXIN_MACROS
      args_const(call).each do |const_name|
        target = resolve_const(const_name, const_prefix)
        add_edge(owner, target_id_for(target, rel), "mixes_in",
                 confidence: confidence_for(target), rel: rel,
                 context: "#{call.name} #{const_name}", call_line: line(call))
      end
    when "scope"
      sym = call.arguments&.arguments&.first
      return unless sym.is_a?(Prism::SymbolNode) || sym.is_a?(Prism::StringNode)

      name = sym.unescaped.to_s
      mid = add_node("#{const_prefix.join('::')}.#{name}",
                     source_file: rel, source_location: line(sym), entity_type: "Method")
      add_containment(owner, mid)
    when "enum"
      emit_enum_accessor(call, owner, const_prefix, rel)
    when "delegate"
      emit_delegate(call, owner, const_prefix, rel)
    end
  end

  def emit_association(call, owner, owner_qualified, const_prefix, rel)
    sym = call.arguments&.arguments&.first
    return unless sym.is_a?(Prism::SymbolNode)

    assoc = sym.unescaped
    options = options_hash(call)
    @stats[:associations] += 1
    return if options["polymorphic"] == true

    relation = ASSOCIATION_RELATIONS[call.name.to_s]
    # has_many/habtm names are plural: Rails derives the class via
    # singularize+camelize (has_many :badges => Badge).
    base = relation == "has_many" ? assoc.to_s.singularize : assoc.to_s
    class_name = options["class_name"].is_a?(String) ? options["class_name"] : camelize(base)
    @assoc_targets[owner_qualified][assoc.to_s] = class_name
    target = resolve_const(class_name, const_prefix)
    props = { "provenance" => "RAILS_DSL", "association" => assoc.to_s }
    props["through"] = options["through"].to_s if options["through"]
    props["foreign_key"] = options["foreign_key"].to_s if options["foreign_key"]
    props["through_relation"] = options["source_type"].to_s if options["source_type"]
    add_edge(owner, target_id_for(target, rel), relation,
             confidence: confidence_for(target), rel: rel,
             context: "#{call.name} :#{assoc}", call_line: line(call), properties: props)
  end

  # `enum :status, { draft: 0, published: 1 }` and `enum :kind, %i[a b]`
  # (positional form) plus legacy `enum status: { draft: 0 }` (keyword
  # form): the value keys become the predicate accessors (`draft?`), not
  # the enum name itself.
  def emit_enum_accessor(call, owner, const_prefix, rel)
    args = Array(call.arguments&.arguments)
    kw = args.find { |a| a.is_a?(Prism::KeywordHashNode) }

    definitions = []
    if kw
      kw.elements.each do |assoc|
        next unless assoc.is_a?(Prism::AssocNode)

        # `enum status: {draft:0}` nests the mapping (the values ARE the
        # inner keys); bare `enum :status, draft: 0` puts the value keys
        # directly in the kwargs.
        case assoc.value
        when Prism::KeywordHashNode, Prism::HashNode, Prism::ArrayNode
          definitions.concat(enum_value_names(assoc.value))
        else
          definitions << assoc.key.unescaped.to_s if assoc.key.respond_to?(:unescaped)
        end
      end
    else
      definitions.concat(enum_value_names(args.second)) if args.second
    end

    definitions.uniq.each do |value|
      mid = add_node("#{const_prefix.join('::')}##{value}?",
                     source_file: rel, source_location: line(call), entity_type: "Method")
      add_containment(owner, mid)
    end
  end

  def enum_value_names(node)
    case node
    when Prism::KeywordHashNode, Prism::HashNode
      node.elements.filter_map do |e|
        e.key.unescaped.to_s if e.is_a?(Prism::AssocNode) && e.key.respond_to?(:unescaped)
      end
    when Prism::ArrayNode
      node.elements.filter_map { |e| e.unescaped.to_s if e.respond_to?(:unescaped) }
    else
      []
    end
  end

  # `to:` is an association/method name, not a class name: resolve it
  # through this class's own association map (`belongs_to :owner,
  # class_name: "User"` => delegate reaches User). Non-association
  # targets (`:class`, `:@ivar`, undefined methods) are skipped — a
  # missing fact beats a false one.
  def emit_delegate(call, owner, const_prefix, rel)
    options = options_hash(call)
    target_sym = options["to"]
    return unless target_sym.is_a?(String) && target_sym.present?

    class_name = @assoc_targets[const_prefix.join("::")][target_sym]
    return unless class_name

    fields = Array(call.arguments&.arguments).filter_map do |a|
      a.unescaped if a.is_a?(Prism::SymbolNode)
    end
    target = resolve_const(class_name, const_prefix)
    add_edge(owner, target_id_for(target, rel), "delegates_to",
             confidence: confidence_for(target), rel: rel,
             context: "delegate #{fields.join(', ')}, to: :#{target_sym}",
             call_line: line(call),
             properties: { "provenance" => "RAILS_DSL", "fields" => fields.map(&:to_s) })
  end

  # ------------------------------------------------------------------
  # Routes
  # ------------------------------------------------------------------
  def scan_routes
    path = @repo.join(ROUTES_FILE)
    return unless path.file?

    program = parse_ok(path.to_s)
    return unless program

    rel = ROUTES_FILE
    file_id = add_node("routes.rb", source_file: rel, entity_type: "File")
    program.statements&.body&.each do |stmt|
      draw = stmt.is_a?(Prism::CallNode) && stmt.name == :draw ? stmt.block : nil
      walk_routes(Array(draw&.body&.body), file_id: file_id, rel: rel,
                  ns_prefix: [], path_prefix: "")
    end
  end

  def walk_routes(statements, file_id:, rel:, ns_prefix:, path_prefix:)
    statements.each do |stmt|
      next unless stmt.is_a?(Prism::CallNode)

      case stmt.name.to_s
      when "resources", "resource"
        emit_resource_routes(stmt, file_id: file_id, rel: rel,
                             ns_prefix: ns_prefix, path_prefix: path_prefix)
      when "namespace", "scope"
        ns, pfx = scope_parts(stmt)
        walk_routes(Array(stmt.block&.body&.body), file_id: file_id, rel: rel,
                    ns_prefix: ns_prefix + ns, path_prefix: path_prefix + pfx)
      when "root"
        arg = stmt.arguments&.arguments&.first
        to = arg.respond_to?(:unescaped) ? arg.unescaped.to_s : ""
        ctrl, action = to.split("#", 2)
        rid = add_node("GET /", source_file: rel, source_location: line(stmt),
                       entity_type: "Route")
        add_containment(file_id, rid)
        emit_routes_to(rid, controller_const(ctrl, ns_prefix), action, rel, stmt)
      when *HTTP_VERBS
        emit_verb_route(stmt, file_id: file_id, rel: rel,
                        ns_prefix: ns_prefix, path_prefix: path_prefix)
      else
        walk_routes(Array(stmt.block&.body&.body), file_id: file_id, rel: rel,
                    ns_prefix: ns_prefix, path_prefix: path_prefix) if stmt.block
      end
    end
  end

  def emit_resource_routes(stmt, file_id:, rel:, ns_prefix:, path_prefix:)
    arg = stmt.arguments&.arguments&.first
    base = arg.respond_to?(:unescaped) ? arg.unescaped.to_s : nil
    return if base.blank?

    options = options_hash(stmt)
    ctrl_const = controller_const(options["controller"].presence || base, ns_prefix)
    base_path = "#{path_prefix}/#{options['path'].presence || base}"
    singular = stmt.name.to_s == "resource"
    actions = REST_ACTIONS.reject { |a, _| singular && a == "index" }
    actions = actions.slice(*Array(options["only"]).map(&:to_s)) if options["only"]
    excepts = Array(options["except"]).map(&:to_s)
    actions = actions.except(*excepts) if excepts.any?

    actions.each do |action, defs|
      defs.each do |(verb, suffix)|
        route_label = "#{verb} #{normalize_path(suffix.gsub(':base', base_path))}"
        rid = add_node(route_label, source_file: rel, source_location: line(stmt),
                       entity_type: "Route")
        add_containment(file_id, rid)
        emit_routes_to(rid, ctrl_const, action, rel, stmt)
      end
    end

    emit_member_blocks(stmt, file_id: file_id, rel: rel, ctrl_const: ctrl_const,
                       base_path: base_path)
  end

  def emit_member_blocks(stmt, file_id:, rel:, ctrl_const:, base_path:)
    Array(stmt.block&.body&.body).each do |sub|
      next unless sub.is_a?(Prism::CallNode)

      # Nested `resources` sit inside the resources block itself:
      # /parents/:id/children.
      if %w[resources resource].include?(sub.name.to_s)
        emit_resource_routes(sub, file_id: file_id, rel: rel,
                             ns_prefix: [], path_prefix: "#{base_path}/:id")
        next
      end
      next unless %w[member collection].include?(sub.name.to_s)

      member = sub.name.to_s == "member"
      Array(sub.block&.body&.body).each do |verb_call|
        next unless verb_call.is_a?(Prism::CallNode)
        next unless HTTP_VERBS.include?(verb_call.name.to_s)

        arg = verb_call.arguments&.arguments&.first
        act = arg.respond_to?(:unescaped) ? arg.unescaped.to_s : nil
        next if act.blank?

        segment = member ? "#{base_path}/:id/#{act}" : "#{base_path}/#{act}"
        rid = add_node("#{verb_call.name.to_s.upcase} #{normalize_path(segment)}",
                       source_file: rel, source_location: line(verb_call), entity_type: "Route")
        add_containment(file_id, rid)
        emit_routes_to(rid, ctrl_const, act, rel, verb_call)
      end
    end
  end

  def emit_verb_route(stmt, file_id:, rel:, ns_prefix:, path_prefix:)
    arg = stmt.arguments&.arguments&.first
    raw = arg.respond_to?(:unescaped) ? arg.unescaped.to_s : nil
    return if raw.blank?

    path = raw.start_with?("/") ? raw : "/#{raw}"
    options = options_hash(stmt)
    to = options["to"].to_s
    ctrl, action =
      if to.include?("#")
        to.split("#", 2)
      elsif options["controller"].present? || options["action"].present?
        segs = path_segments(path)
        [ options["controller"].to_s.presence || segs.first.to_s,
          options["action"].to_s.presence || segs.last.to_s ]
      else
        # Rails convention for a bare verb route: leading segments are the
        # controller path, the LAST segment is the action; a lone segment
        # defaults its action to `index` (`get 'health'` => `health#index`).
        segs = path_segments(path)
        [ segs[0..-2].presence&.join("/") || segs.first.to_s,
          segs.size > 1 ? segs.last.to_s : "index" ]
      end
    ctrl_const = controller_const(ctrl, ns_prefix)
    verb = stmt.name.to_s == "match" ? "MATCH" : stmt.name.to_s.upcase
    rid = add_node("#{verb} #{normalize_path(path_prefix + path)}", source_file: rel,
                   source_location: line(stmt), entity_type: "Route")
    add_containment(file_id, rid)
    emit_routes_to(rid, ctrl_const, action, rel, stmt)
  end

  def emit_routes_to(rid, ctrl_const, action, rel, stmt)
    return if ctrl_const.blank? || action.blank?

    # Undeclared actions are route-stub Method nodes: no source_file →
    # no provenance (a route mentioning `#stats` doesn't "define" it).
    decl = @method_decls["#{ctrl_const}##{action}"]
    mid = add_node("#{ctrl_const}##{action}",
                   source_file: decl ? decl[:file] : nil,
                   source_location: decl ? decl[:line] : nil,
                   entity_type: "Method")
    add_containment(add_node(ctrl_const, source_file: nil, entity_type: "Class"), mid)
    add_edge(rid, mid, "routes_to", confidence: "EXTRACTED", rel: rel,
             context: "routes_to #{ctrl_const}##{action}", call_line: line(stmt),
             properties: { "provenance" => "RAILS_DSL" })
  end

  def controller_const(base, ns_prefix)
    (ns_prefix + [ "#{camelize(base)}Controller" ]).join("::")
  end

  def scope_parts(stmt)
    arg = stmt.arguments&.arguments&.first
    name = arg.respond_to?(:unescaped) ? arg.unescaped.to_s : ""
    if stmt.name.to_s == "namespace"
      [ [ camelize(name) ], "/#{name}" ]
    else
      options = options_hash(stmt)
      ns = options["module"].to_s.presence&.split("/")&.map { |s| camelize(s) } || []
      pfx = options["path"].to_s.presence || (name.present? ? "/#{name}" : "")
      [ ns, pfx ]
    end
  end

  # ------------------------------------------------------------------
  # Resolution + emission helpers
  # ------------------------------------------------------------------
  # Lexical order first (enclosing namespace outward, then top level) —
  # that is exactly how Ruby resolves the constant at runtime, so a single
  # lexical match is EXTRACTED, not review-worthy. When nothing lexical
  # matches, fall back to a basename search across every declaration:
  # one match is a good INFERRED guess (a real constant beats inventing
  # one), several distinct matches is genuinely undecidable → AMBIGUOUS.
  def resolve_const(name, const_prefix)
    return { status: :unresolved, guess: name } if name.blank?

    candidates = []
    prefix = const_prefix.dup
    until prefix.empty?
      candidates << (prefix + [ name ]).join("::")
      prefix.pop
    end
    candidates << name
    candidates.uniq!

    if (lexical = candidates.find { |candidate| @const_decls.key?(candidate) })
      return { status: :resolved, name: lexical }
    end

    short = name.split("::").last
    basename_hits = @basename_index[short]
    return { status: :inferred, name: basename_hits.first } if basename_hits.size == 1
    return { status: :ambiguous, candidates: basename_hits } if basename_hits.size > 1

    { status: :unresolved, guess: name }
  end

  def confidence_for(target)
    case target[:status]
    when :resolved then "EXTRACTED"
    when :ambiguous then "AMBIGUOUS"
    else "INFERRED" # unresolved/basename best-guess reference
    end
  end

  # Resolved/inferred targets point at their real declaration. UNRESOLVED
  # targets are reference-only stubs: no source_file (the importer writes
  # no provenance obs for them) and a "reference" marker — the importer
  # treats them as claimable placeholders so the repo that actually
  # declares the constant can merge real provenance in later, regardless
  # of import order.
  def target_id_for(target, rel)
    name = target[:status] == :ambiguous ? target[:candidates].first : target[:name] || target[:guess]
    if target[:status] == :resolved || target[:status] == :inferred
      decl = @const_decls[name].first
      add_node(name, source_file: decl ? decl[:file] : rel,
             source_location: decl ? decl[:line] : nil, entity_type: "Class")
    else
      add_node(name, source_file: nil, entity_type: "Class",
               extra_obs: [], reference: true)
    end
  end

  def add_node(label, source_file:, source_location: nil, entity_type: nil, extra_obs: [], reference: false)
    key = "#{entity_type}:#{label}"
    if (existing = @node_ids[key])
      node = @nodes_by_id[existing]
      node["source_file"] ||= source_file
      node["source_location"] ||= source_location
      (node["observations"] ||= []).concat(extra_obs) if extra_obs.any?
      return existing
    end

    id = "n#{@nodes.size}"
    node = { "id" => id, "label" => label, "source_file" => source_file,
             "source_location" => source_location }.compact
    node["entity_type"] = entity_type if entity_type
    node["reference"] = true if reference
    node["observations"] = extra_obs if extra_obs.any?
    @nodes << node
    @node_ids[key] = id
    @nodes_by_id[id] = node
    id
  end

  def add_containment(parent_id, child_id)
    return if parent_id.nil? || child_id.nil? || parent_id == child_id

    @links << { "source" => parent_id, "target" => child_id,
                "relation" => "contains", "confidence" => "EXTRACTED",
                "confidence_score" => 1.0, "weight" => 1.0 }
  end

  def add_edge(from_id, to_id, relation, confidence:, rel:, context: nil, call_line: nil, properties: {})
    return if from_id.nil? || to_id.nil? || from_id == to_id

    @links << {
      "source" => from_id, "target" => to_id, "relation" => relation,
      "confidence" => confidence, "confidence_score" => confidence == "AMBIGUOUS" ? 0.5 : 0.9,
      "weight" => 1.0, "context" => context,
      "source_file" => rel, "source_location" => call_line,
      "properties" => { "provenance" => "RAILS_DSL" }.merge(properties)
    }.compact
  end

  # ------------------------------------------------------------------
  # Small helpers
  # ------------------------------------------------------------------
  def const_full_name(node)
    case node
    when Prism::ConstantReadNode then node.name.to_s
    when Prism::ConstantPathNode then collect_const_path(node)
    else node.respond_to?(:name) ? node.name.to_s : node.to_s
    end
  end

  def collect_const_path(node)
    case node
    when Prism::ConstantReadNode
      node.name.to_s
    when Prism::ConstantPathNode
      parent = node.parent ? collect_const_path(node.parent) : nil
      [ parent, node.name.to_s ].compact.join("::")
    else
      node.to_s
    end
  end

  def args_const(call)
    Array(call.arguments&.arguments).filter_map do |arg|
      collect_const_path(arg) if arg.is_a?(Prism::ConstantReadNode) || arg.is_a?(Prism::ConstantPathNode)
    end
  end

  def options_hash(call)
    kw = call.arguments&.arguments&.find { |a| a.is_a?(Prism::KeywordHashNode) }
    return {} unless kw

    kw.elements.each_with_object({}) do |assoc, hash|
      next unless assoc.is_a?(Prism::AssocNode)

      key = assoc.key.respond_to?(:unescaped) ? assoc.key.unescaped : assoc.key.to_s
      value = assoc.value
      hash[key.to_s] =
        case value
        when Prism::SymbolNode then value.unescaped
        when Prism::StringNode then value.unescaped
        when Prism::TrueNode then true
        when Prism::FalseNode then false
        when Prism::ArrayNode
          value.elements.map do |e|
            e.respond_to?(:unescaped) ? e.unescaped : e.to_s
          end
        when Prism::ConstantReadNode, Prism::ConstantPathNode then collect_const_path(value)
        else value.respond_to?(:unescaped) ? value.unescaped : value.to_s
        end
    end
  end

  def class_observations(stmt)
    return [] unless stmt.is_a?(Prism::ClassNode) && stmt.superclass

    [ { "content" => "Superclass: #{collect_const_path(stmt.superclass)}",
        "source" => PRODUCER, "confidence" => 0.9,
        "tags" => [ PRODUCER, "superclass" ] } ]
  end

  def camelize(str)
    str.to_s.split("::").map do |part|
      part.split("/").map { |s| s.split("_").map(&:capitalize).join }.join("::")
    end.join("::")
  end

  def line(node)
    "L#{node.location.start_line}"
  end

  def relative(path)
    Pathname.new(path).relative_path_from(@repo).to_s
  end

  def normalize_path(path)
    path.gsub(%r{/+}, "/")
  end

  def path_segments(path)
    path.split("/").reject { |s| s.blank? || s.start_with?(":", "(") }
  end
end
