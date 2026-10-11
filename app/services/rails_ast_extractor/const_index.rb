# frozen_string_literal: true

# Pass 1 + constant resolution for RailsAstExtractor: indexes every
# class/module/def declaration before any edge is emitted, then resolves
# association/mixin/superclass names lexical-first (exactly how Ruby does)
# with a conservative basename fallback.
class RailsAstExtractor
  module ConstIndex
  private

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

        qualified = qualified_name(const_prefix, name)
        entity_type = stmt.is_a?(Prism::ModuleNode) ? "Module" : "Class"
        @const_decls[qualified] << { file: rel, line: line(stmt), type: entity_type }
        @basename_index[qualified.split("::").last] |= [ qualified ]
        walk_index(Array(stmt.body&.body), const_prefix: qualified.split("::"), rel: rel)
      when Prism::SingletonClassNode
        # `class << self` defs index under the same `Owner.self.name`
        # labels pass 2 emits (see walk_emit).
        walk_index(Array(stmt.body&.body), const_prefix: const_prefix + [ "self" ], rel: rel)
      when Prism::DefNode
        sep = stmt.receiver || const_prefix.last == "self" ? "." : "#"
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
  # Constant resolution.
  # ------------------------------------------------------------------
  # Lexical order first (enclosing namespace outward, then top level) —
  # that is exactly how Ruby resolves the constant at runtime, so a single
  # lexical match is EXTRACTED, not review-worthy. When nothing lexical
  # matches, fall back to a basename search across every declaration:
  # one match is a good INFERRED guess (a real constant beats inventing
  # one), several distinct matches is genuinely undecidable → AMBIGUOUS.
  def resolve_const(name, const_prefix)
    return { status: :unresolved, guess: name } if name.blank?

    absolute = name.start_with?("::")
    name = name.delete_prefix("::")

    if absolute
      # `::User` names the top-level constant only — no lexical prefix walk.
      return { status: :resolved, name: name } if @const_decls.key?(name)

      return { status: :unresolved, guess: name }
    end

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

    # A qualified name is an explicit namespace claim: `Vendor::User`
    # must not basename-match `Admin::User`. Unresolved → reference stub.
    return { status: :unresolved, guess: name } if name.include?("::")

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
  def target_id_for(target, rel, stub_type: "Class")
    name = target[:status] == :ambiguous ? target[:candidates].first : target[:name] || target[:guess]
    if target[:status] == :resolved || target[:status] == :inferred
      decl = @const_decls[name].first
      add_node(name, source_file: decl ? decl[:file] : rel,
             source_location: decl ? decl[:line] : nil,
             entity_type: decl ? decl[:type] : "Class")
    else
      add_node(name, source_file: nil, entity_type: stub_type,
               extra_obs: [], reference: true)
    end
  end

  # Joins a declared constant path onto the enclosing namespace.
  # Inside `module Admin`, `class Admin::User` re-states the namespace —
  # Ruby resolves the leading segment to `::Admin`, not `Admin::Admin` —
  # so a head segment equal to the current prefix's last element is NOT
  # re-prefixed. Absolute paths (`::Foo`) ignore the prefix entirely.
  def qualified_name(const_prefix, name)
    return name.delete_prefix("::") if name.start_with?("::")

    parts = name.split("::")
    # Restated PATHS only (`class Admin::User` inside `module Admin` →
    # `Admin::User`, not `Admin::Admin::User`): a multi-segment head matching
    # ANY enclosing segment splices there, so `module A; module B; class A::X`
    # → `A::X`. A single-segment name is always nested (`class Admin` inside
    # `module Admin` IS `Admin::Admin`), otherwise `Module:Admin` and
    # `Class:Admin` collide on the globally-unique entity name.
    if parts.size > 1 && const_prefix.any?
      idx = const_prefix.rindex(parts.first)
      return (const_prefix[0..idx] + parts[1..]).join("::") if idx
    end

    (const_prefix + parts).join("::")
  end

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
      # `::Top` parses as a path node with a nil parent — keep the leading
      # `::` so qualified_name/resolve_const see the absolute marker.
      return "::#{node.name}" if node.parent.nil?

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
  end
end
