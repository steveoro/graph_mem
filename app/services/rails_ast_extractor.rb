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
#
# Layout: orchestration + node/edge primitives live here; pass-1 indexing
# and constant resolution live in RailsAstExtractor::ConstIndex; the DSL
# emitters live in RailsAstExtractor::DslEmitters.
class RailsAstExtractor
  include ConstIndex
  include DslEmitters

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
    @pending_delegates = []                        # delegates awaiting a later-declared `to:` assoc
    @stats = Hash.new(0)
  end

  def extract
    files = ruby_files
    # Pass 1: index every declaration so pass 2 resolves order-independently.
    files.each { |f| index_file(f) }
    files.each { |f| emit_file(f) }
    @parse_cache.clear # ASTs are only needed across the two passes
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

        qualified = qualified_name(const_prefix, name)
        entity_type = stmt.is_a?(Prism::ModuleNode) ? "Module" : "Class"
        node_id = add_node(qualified, source_file: rel, source_location: line(stmt),
                           entity_type: entity_type)
        add_containment(parent_for(file_id, const_prefix), node_id)
        emit_inherits(stmt, node_id, const_prefix, rel)
        walk_emit(Array(stmt.body&.body), file_id: node_id, rel: rel,
                  const_prefix: qualified.split("::"))
        drain_delegates(qualified, rel)
      when Prism::SingletonClassNode
        # `class << self` defs are singleton methods: emit them as
        # `Owner.self.name` so they stay distinct from `Owner#name`
        # instance methods and `Owner.name` scope accessors. NOTE: a
        # `def self.name` (receiver form) still emits `Owner.name` — the
        # two spellings produce different labels by design choice, so a
        # review never conflates a declared receiver with the singleton
        # block spelling.
        walk_emit(Array(stmt.body&.body), file_id: file_id, rel: rel,
                  const_prefix: const_prefix + [ "self" ])
      when Prism::DefNode
        # Inside `class << self` a receiver-less def is a singleton method,
        # labelled `Owner.self.name` (design choice Steve approved — it stays
        # distinct from the `def self.name` receiver form, which emits
        # `Owner.name`). The trailing "self" marker is NOT a real constant,
        # so the method still parents under the enclosing class/module.
        real_prefix = const_prefix.last == "self" ? const_prefix[0..-2] : const_prefix
        label = if const_prefix.last == "self" && stmt.receiver.nil?
                  "#{real_prefix.join('::')}.self.#{stmt.name}"
        else
                  sep = stmt.receiver ? "." : "#"
                  "#{real_prefix.join('::')}#{sep}#{stmt.name}"
        end
        node_id = add_node(label, source_file: rel, source_location: line(stmt),
                           entity_type: "Method")
        add_containment(parent_for(file_id, real_prefix), node_id)
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
      node.is_a?(Prism::UnlessNode) || node.is_a?(Prism::CaseNode) ||
      node.is_a?(Prism::StatementsNode) || node.is_a?(Prism::SingletonClassNode)
  end

  def parent_for(file_id, const_prefix)
    return file_id if const_prefix.empty?

    add_node(const_prefix.join("::"), source_file: nil,
             entity_type: declared_type(const_prefix.join("::")) || "Class")
  end

  # The entity_type a qualified constant was DECLARED with (module vs
  # class) — reusing it keeps stubs from duplicating the real node under
  # a different type key (Module:Admin vs Class:Admin).
  def declared_type(qualified)
    @const_decls[qualified].first&.dig(:type)
  end

  # ------------------------------------------------------------------
  # Node/edge primitives
  # ------------------------------------------------------------------
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
