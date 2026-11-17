# frozen_string_literal: true

module GraphMem
  module McpApps
    # Builds a ui:// view document (MCP Apps step B, 1.88.0): the HTML shell from
    # lib/graph_mem/mcp_apps/view/ with one inline <script type="module"> holding, in order, the
    # vendored Cytoscape, the Explore graph config and the view's own scripts. Hosts render views
    # under a CSP with no network access and no importmap, so everything is inlined and the module
    # syntax of the reused files is rewritten:
    # - Cytoscape's exact trailer `export{Ah as default};` becomes a return from a function scope,
    #   so its minified top-level names can't clash with the view's;
    # - the config's two `export const` lose their `export ` (LAYOUT_OPTIONS holds a function, so
    #   the source is inlined rather than serialized).
    # A changed vendored file or config fails the build (and the pinning specs) instead of
    # shipping a broken view. Nothing is copied: the sources stay where Explore uses them.
    #
    # @example
    #   ViewBuilder.document(shell: "graph.html", scripts: %w[bridge.js graph_view.js])
    #   # => "<!doctype html>…<script type=\"module\">…</script>…" (built once per process)
    module ViewBuilder
      class BuildError < StandardError; end

      SOURCE_DIR = Pathname(__dir__).join("view")
      CYTOSCAPE_PATH = Pathname(__dir__).join("../../../vendor/javascript/cytoscape.js-3.31.4-dist/cytoscape.esm.min.mjs").cleanpath
      CYTOSCAPE_TRAILER = "export{Ah as default};\n"
      CONFIG_PATH = Pathname(__dir__).join("../../../app/javascript/graph/cytoscape_config.js").cleanpath
      CONFIG_EXPORTS = [ "export const GRAPH_STYLES", "export const LAYOUT_OPTIONS" ].freeze
      # The shell's placeholder for the built script (a JS comment, so the bare shell still parses).
      SCRIPT_MARKER = "/* graph_mem: view scripts */"

      @documents = {}
      @lock = Mutex.new

      # @param shell [String] HTML shell file name under SOURCE_DIR, holding SCRIPT_MARKER once
      # @param scripts [Array<String>] view script file names under SOURCE_DIR, in load order
      # @return [String] the built HTML document, memoized per (shell, scripts)
      # @raise [BuildError] when a reused source no longer has the shape the rewrites expect
      def self.document(shell:, scripts:)
        key = [ shell, *scripts ].join("\0")
        @lock.synchronize { @documents[key] ||= build(shell: shell, scripts: scripts).freeze }
      end

      # @return [String] the built document, not memoized (specs)
      def self.build(shell:, scripts:)
        html = SOURCE_DIR.join(shell).read
        raise BuildError, "#{shell} must hold #{SCRIPT_MARKER} once" unless html.scan(SCRIPT_MARKER).size == 1

        parts = [ cytoscape_source, config_source, *scripts.map { |name| view_script(name) } ]
        html.sub(SCRIPT_MARKER) { parts.join("\n") }
      end

      # @return [String] Cytoscape wrapped in a function scope that returns its default export as
      #   the `cytoscape` constant
      def self.cytoscape_source
        source = CYTOSCAPE_PATH.read
        raise BuildError, "Cytoscape no longer ends with #{CYTOSCAPE_TRAILER.inspect}" unless source.end_with?(CYTOSCAPE_TRAILER)

        body = source.delete_suffix(CYTOSCAPE_TRAILER)
        "// Cytoscape.js 3.31.4 (MIT), vendor/javascript/, inlined by GraphMem::McpApps::ViewBuilder.\n" \
          "const cytoscape = (() => {\n#{body}\nreturn Ah;\n})();\n"
      end

      # @return [String] the Explore graph config with its two exports turned into local constants
      def self.config_source
        source = CONFIG_PATH.read
        found = source.scan(/^export .*$/).map { |line| line[/\Aexport const \w+/] }
        raise BuildError, "cytoscape_config.js exports changed: #{found.inspect}" unless found == CONFIG_EXPORTS

        "// app/javascript/graph/cytoscape_config.js, inlined.\n" + source.gsub(/^export /, "")
      end

      def self.view_script(name)
        source = SOURCE_DIR.join(name).read
        raise BuildError, "#{name} must not use module syntax" if source.match?(/^\s*(import|export)\b/)

        "// lib/graph_mem/mcp_apps/view/#{name}\n#{source}"
      end
      private_class_method :view_script
    end
  end
end
