# frozen_string_literal: true

require "rails_helper"

# Skills over MCP (1.91.0, SEP-2640, io.modelcontextprotocol/skills) behind mcp_skills_enabled.
# Off (the default) the wire is 1.90.0's; on, only the Skills surface is added. In-process JSON-RPC
# against the real servers and the repo's real skills/ (read-only); synth-* skills in a temp
# directory where a spec needs another skill.
RSpec.describe "Skills over MCP on the wire" do
  profiles = %i[default readonly maintenance]
  list_methods = %w[tools/list prompts/list resources/templates/list resources/list]
  ui = { "io.modelcontextprotocol/ui" => { "mimeTypes" => [ "text/html;profile=mcp-app" ] } }
  skills_ext = { "io.modelcontextprotocol/skills" => {} }
  tool_counts = { default: 12, readonly: 9, maintenance: 22 }

  def rpc(server, method, params = nil)
    request = { jsonrpc: "2.0", id: 1, method: method }
    request[:params] = params if params
    JSON.parse(JSON.generate(server.handle(request)))
  end

  def capabilities(server)
    rpc(server, "initialize", { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "SynthClient", version: "0" } })
      .dig("result", "capabilities")
  end

  def sorted(result) = result.transform_values { |items| items.is_a?(Array) ? items.sort_by { |item| item["name"].to_s } : items }

  def factory(profile, **options) = GraphMem::OfficialMcp::ServerFactory.for(profile, **options)

  let(:base) { GraphMem::OfficialMcp::ServerFactory::CAPABILITIES.deep_stringify_keys }
  let(:toolset) { Rails.root.join("skills/graph-mem-mcp-toolset") }

  describe "off (the default): 1.90.0's wire" do
    it "is off by default" do
      expect(GraphMem::McpSkills.enabled?).to be(false)
    end

    profiles.each do |profile|
      it "#{profile}: the recorded lists, today's capabilities with Apps on and off, no skills methods" do
        server = factory(profile)
        recorded = JSON.parse(Rails.root.join("spec/fixtures/mcp/snapshots/#{profile}.json").read)
        list_methods.each do |method|
          expect(JSON.pretty_generate(sorted(rpc(server, method)["result"]))).to eq(JSON.pretty_generate(sorted(recorded[method]))), method
        end

        expect(capabilities(server)).to eq(base.merge("extensions" => ui))
        expect(capabilities(factory(profile, apps_enabled: false))).to eq(base)
        expect(GraphMem::OfficialMcp::ServerFactory.capabilities(apps_enabled: false)).to equal(GraphMem::OfficialMcp::ServerFactory::CAPABILITIES)
        expect(rpc(server, "skills/list").dig("error", "code")).to eq(-32_601)
        expect(rpc(server, "resources/read", { uri: "skill://graph-mem-mcp-toolset/SKILL.md" }).dig("error", "code")).to eq(-32_602)
        expect(rpc(server, "tools/list").dig("result", "tools").size).to eq(tool_counts.fetch(profile))
      end
    end
  end

  describe "on" do
    it "declares the extension alone, or next to MCP Apps, with no directoryRead" do
      expect(capabilities(factory(:default, apps_enabled: false, skills_enabled: true))).to eq(base.merge("extensions" => skills_ext))
      expect(capabilities(factory(:default, apps_enabled: true, skills_enabled: true))).to eq(base.merge("extensions" => ui.merge(skills_ext)))
    end

    profiles.each do |profile|
      it "#{profile}: lists its skills with sizes and SHA-256 digests, and keeps the tools, prompts and templates" do
        on = factory(profile, skills_enabled: true)
        off = factory(profile, skills_enabled: false)
        listed = rpc(on, "skills/list").dig("result", "skills")
        expected = GraphMem::McpSkills::PROFILES.select { |_name, served| served.include?(profile) }.keys.sort

        expect(listed.map { |skill| skill["uri"] }).to eq(expected.map { |name| "skill://#{name}/SKILL.md" })
        listed.flat_map { |skill| skill["resources"] }.each do |entry|
          path = Rails.root.join("skills", entry["uri"].delete_prefix("skill://"))
          expect(entry).to eq("uri" => entry["uri"], "size" => path.size, "digest" => "sha256:#{Digest::SHA256.hexdigest(path.binread)}")
        end
        %w[tools/list prompts/list resources/templates/list].each { |method| expect(rpc(on, method)).to eq(rpc(off, method)), method }
        expect(rpc(on, "tools/list").dig("result", "tools").size).to eq(tool_counts.fetch(profile))
        skill_entries = rpc(on, "resources/list").dig("result", "resources") - rpc(off, "resources/list").dig("result", "resources")
        expect(skill_entries.map { |entry| [ entry["uri"], entry["mimeType"] ] }).to match_array(listed.map { |skill| [ skill["uri"], "text/markdown" ] })
      end
    end

    it "keeps project-scan off readonly: not listed, not gettable, not readable" do
      readonly = factory(:readonly, skills_enabled: true)

      expect(rpc(readonly, "skills/list").dig("result", "skills").map { |skill| skill["uri"] }).not_to include(a_string_including("project-scan"))
      expect(rpc(readonly, "skills/get", { uri: "skill://project-scan/SKILL.md" })).to include("error")
      expect(rpc(readonly, "resources/read", { uri: "skill://project-scan/SKILL.md" }).dig("error", "code")).to eq(-32_602)
      expect(rpc(factory(:default, skills_enabled: true), "resources/read", { uri: "skill://project-scan/SKILL.md" })).to have_key("result")
    end

    it "gets a skill by URI with its manifest" do
      skill = rpc(factory(:readonly, skills_enabled: true), "skills/get", { uri: "skill://graph-mem-mcp-toolset/SKILL.md" }).dig("result", "skill")

      expect(skill["uri"]).to eq("skill://graph-mem-mcp-toolset/SKILL.md")
      expect(skill.dig("frontmatter", "name")).to eq("graph-mem-mcp-toolset")
      expect(skill["resources"].size).to eq(4)
    end

    it "reads SKILL.md and a references/ file byte for byte, and the template and view resources as before" do
      server = factory(:default, apps_enabled: true, skills_enabled: true)
      read = ->(uri) { rpc(server, "resources/read", { uri: uri }).dig("result", "contents", 0) }

      expect(read.("skill://graph-mem-mcp-toolset/SKILL.md")["text"]).to eq(toolset.join("SKILL.md").read)
      expect(read.("skill://graph-mem-mcp-toolset/references/tools.md")["text"]).to eq(toolset.join("references/tools.md").read)
      expect(read.("ui://graph-mem/graph")["mimeType"]).to eq("text/html;profile=mcp-app")
      entity = MemoryEntity.create!(name: "synth-skills-entity", entity_type: "Task")
      templated = rpc(server, "resources/read", { uri: "memory_entities?id=#{entity.id}" }).dig("result", "contents", 0, "text")
      expect(templated).to include("synth-skills-entity")
    end

    it "answers a skill:// URI that names no served file with -32602, like the gem's reader" do
      server = factory(:default, skills_enabled: true)

      expect(rpc(server, "resources/read", { uri: "skill://graph-mem-mcp-toolset/synth-missing.md" })["error"])
        .to include("code" => -32_602, "message" => 'Skill file not found: "skill://graph-mem-mcp-toolset/synth-missing.md"')
      expect(rpc(server, "resources/read", { uri: "skill://synth-unknown/SKILL.md" }).dig("error", "code")).to eq(-32_602)
    end

    it "matches URIs as exact strings: path-shaped ones reach no file, across the readonly boundary either" do
      readonly = factory(:readonly, skills_enabled: true)
      default = factory(:default, skills_enabled: true)

      %w[skill://graph-mem-mcp-toolset/../project-scan/SKILL.md skill://graph-mem-mcp-toolset/%2e%2e/project-scan/SKILL.md
         skill://graph-mem-mcp-toolset//SKILL.md SKILL://graph-mem-mcp-toolset/SKILL.md].each do |uri|
        expect(rpc(readonly, "resources/read", { uri: uri }).dig("error", "code")).to eq(-32_602), uri
      end
      expect(rpc(default, "resources/read", { uri: "skill://graph-mem-mcp-toolset/references/../SKILL.md" }).dig("error", "code")).to eq(-32_602)
      expect(rpc(default, "resources/read", { uri: "skill://graph-mem-mcp-toolset/../../../etc/passwd" }).dig("error", "code")).to eq(-32_602)
    end

    it "scrubs a URI that isn't valid UTF-8 in the refusal, so the reply still encodes as -32602" do
      uri = "skill://graph-mem-mcp-toolset/synth-\xFF.md".dup.force_encoding(Encoding::UTF_8)

      expect(rpc(factory(:default, skills_enabled: true), "resources/read", { uri: uri }).dig("error", "code")).to eq(-32_602)
    end

    it "builds without the extension, tools intact, when a file under skills/ can't be loaded" do
      Dir.mktmpdir("mcp-skills") do |root|
        FileUtils.mkdir_p(File.join(root, "synth-alpha"))
        File.write(File.join(root, "synth-alpha", "SKILL.md"), "---\nname: synth-alpha\ndescription: A synthetic skill for specs.\n---\n")
        File.write(File.join(root, "synth-alpha", "#SKILL.md#"), "a stray editor file")
        stub_const("GraphMem::McpSkills::ROOT", root)
        allow(Rails.logger).to receive(:warn).and_call_original
        server = factory(:default, apps_enabled: false, skills_enabled: true)

        expect(capabilities(server)).to eq(base)
        expect(rpc(server, "tools/list").dig("result", "tools").size).to eq(12)
        expect(rpc(server, "skills/list").dig("error", "code")).to eq(-32_601)
        expect(Rails.logger).to have_received(:warn).with(a_string_starting_with("[McpSkills] skills not served on default:"))
      end
    end

    it "serves a rebuilt server's skills from disk at build time (synth skills in a temp directory)" do
      Dir.mktmpdir("mcp-skills") do |root|
        FileUtils.mkdir_p(File.join(root, "synth-alpha"))
        File.write(File.join(root, "synth-alpha", "SKILL.md"), "---\nname: synth-alpha\ndescription: A synthetic skill for specs.\n---\n\nSynth body.\n")
        stub_const("GraphMem::McpSkills::ROOT", root)
        stub_const("GraphMem::McpSkills::PROFILES", { "synth-alpha" => %i[default readonly maintenance] })
        server = factory(:readonly, skills_enabled: true)

        expect(rpc(server, "skills/list").dig("result", "skills").map { |skill| skill["uri"] }).to eq([ "skill://synth-alpha/SKILL.md" ])
        expect(rpc(server, "resources/read", { uri: "skill://synth-alpha/SKILL.md" }).dig("result", "contents", 0, "text")).to include("Synth body.")
      end
    end
  end

  describe "the mcp_skills_enabled setting" do
    after { AppSettings.where(var: "mcp_skills_enabled").delete_all }

    it "turned on, makes the servers built from it serve the skills" do
      AppSettings.mcp_skills_enabled = true
      AppSettings.clear_cache

      expect(capabilities(factory(:maintenance)).dig("extensions", "io.modelcontextprotocol/skills")).to eq({})
      expect(rpc(factory(:maintenance), "skills/list").dig("result", "skills").size).to eq(2)
    end
  end
end
