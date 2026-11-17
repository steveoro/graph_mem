# frozen_string_literal: true

require "rails_helper"
require "digest"

# MCP Apps Graph mode (1.88.0): the view document inlines the vendored Cytoscape and Explore's
# graph config. These pins make a Cytoscape bump or a config change fail here, loudly, instead of
# shipping a view that breaks inside the host.
RSpec.describe GraphMem::McpApps::ViewBuilder do
  let(:view) { GraphMem::McpApps::Views::VIEWS.first }
  let(:document) { described_class.build(shell: view[:source], scripts: view[:scripts]) }
  let(:cytoscape) { described_class::CYTOSCAPE_PATH.read }

  describe "the vendored Cytoscape 3.31.4" do
    it "is the pinned file" do
      expect(cytoscape.bytesize).to eq(416_235)
      expect(Digest::SHA256.hexdigest(cytoscape)).to eq("2815a1007610f002a3fc89a28e3172534603c9439833a4d3fa4e172576b7e2d3")
      expect(cytoscape).to end_with("export{Ah as default};\n")
    end

    it "is still under vendor/javascript/ and not copied among the view sources" do
      expect(described_class::CYTOSCAPE_PATH.relative_path_from(Rails.root).to_s).to eq("vendor/javascript/cytoscape.js-3.31.4-dist/cytoscape.esm.min.mjs")
      expect(Rails.root.glob("lib/graph_mem/mcp_apps/**/*cytoscape*")).to be_empty
    end

    it "is inlined in a function scope that returns its default export" do
      expect(document).to include("const cytoscape = (() => {\n", "\nreturn Ah;\n})();\n")
      expect(document).not_to include("export{Ah as default}")
    end
  end

  describe "the Explore graph config" do
    it "has exactly the two exports the builder rewrites" do
      exports = described_class::CONFIG_PATH.read.scan(/^export .*$/).map { |line| line[/\Aexport const \w+/] }
      expect(exports).to eq([ "export const GRAPH_STYLES", "export const LAYOUT_OPTIONS" ])
    end

    it "is inlined as source, without its exports" do
      expect(document).to include("const GRAPH_STYLES = [", "const LAYOUT_OPTIONS = {", "animateFilter: function")
      expect(document).not_to match(/^export /)
    end
  end

  describe "the built document" do
    it "puts every script, in order, in the shell's one module script" do
      scripts = Nokogiri::HTML5.parse(document).css("script")
      expect(scripts.map { |script| script["type"] }).to eq([ "module" ])

      text = scripts.sole.text
      order = [ "const cytoscape = (() => {", "const GRAPH_STYLES", *view[:scripts].map { |name| "// lib/graph_mem/mcp_apps/view/#{name}" } ]
      expect(order.map { |marker| text.index(marker) }).to all(be_an(Integer)).and(eq(order.map { |marker| text.index(marker) }.sort))
    end

    # The view-source spec forbids these in the view's own sources; in the built document they
    # may appear only as often as the vendored file has them: http: in its license comments, one
    # Function("return this")() fallback and "import" in its error text.
    {
      "an http: URL" => /http:/, "an https: URL" => /https:/, "Function(" => /Function\(/, "import" => /\bimport\b/,
      "innerHTML" => /innerHTML/, "outerHTML" => /outerHTML/, "insertAdjacentHTML" => /insertAdjacentHTML/,
      "document.write" => /document\.write/, "eval(" => /\beval\s*\(/, "fetch(" => /\bfetch\s*\(/,
      "XMLHttpRequest" => /XMLHttpRequest/, "WebSocket" => /WebSocket/
    }.each do |label, pattern|
      it "has #{label} only where the vendored Cytoscape has it" do
        expect(document.scan(pattern).size).to eq(cytoscape.scan(pattern).size)
      end
    end

    it "has no HTML-breaking sequence inside the script" do
      script = document[/<script type="module">\n(.*)<\/script>/m, 1]
      expect(script).not_to include("</script", "<!--")
    end

    it "is built once per process" do
      first = described_class.document(shell: view[:source], scripts: view[:scripts])
      expect(described_class.document(shell: view[:source], scripts: view[:scripts])).to be(first)
      expect(first).to be_frozen.and eq(document)
    end
  end

  describe "when a reused source changes shape" do
    it "refuses a Cytoscape without the pinned trailer" do
      Tempfile.create([ "cytoscape", ".mjs" ]) do |file|
        file.write(cytoscape.sub("export{Ah as default};", "export{Bh as default};"))
        file.flush
        stub_const("#{described_class}::CYTOSCAPE_PATH", Pathname(file.path))

        expect { described_class.cytoscape_source }.to raise_error(described_class::BuildError, /trailer|ends with/)
      end
    end

    it "refuses a config with another export" do
      Tempfile.create([ "config", ".js" ]) do |file|
        file.write("#{described_class::CONFIG_PATH.read}\nexport const EXTRA = 1;\n")
        file.flush
        stub_const("#{described_class}::CONFIG_PATH", Pathname(file.path))

        expect { described_class.config_source }.to raise_error(described_class::BuildError, /exports changed/)
      end
    end
  end
end
