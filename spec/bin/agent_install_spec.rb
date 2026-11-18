# frozen_string_literal: true

require "spec_helper"
require "json"
require "open3"
require "tmpdir"

# Auto-adoption A5 (1.90.0): bin/agent-install is print-only (plan decision D2). Run under a
# throwaway HOME, it prints the Claude Code and Cursor blocks and writes nothing anywhere.
RSpec.describe "bin/agent-install" do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:script) { File.join(root, "bin/agent-install") }

  around do |example|
    Dir.mktmpdir("agent-install-home") do |home|
      @home = home
      example.run
    end
  end

  def run_install(*args)
    # Outside the bundle, as a user runs it (bundle exec's RUBYOPT makes RubyGems warn on CI).
    Bundler.with_unbundled_env { Open3.capture3({ "HOME" => @home }, "ruby", script, *args, chdir: @home) }
  end

  # The JSON snippets: from a line that is "{" (after the indent) to the "}" line at that indent.
  def json_blocks(out)
    out.to_enum(:scan, /^( *)\{\n.*?^\1\}$/m).map { JSON.parse(Regexp.last_match(0)) }
  end

  it "prints the Claude Code block, then the Cursor block, and leaves HOME empty" do
    out, err, status = run_install

    expect(status).to be_success
    expect(err).to be_empty
    expect(out.index("== Claude Code ==")).to be < out.index("== Cursor ==")
    expect(out).to include(%(cd "#{root}")) # quoted: the repo path may hold a space
    expect(Dir.children(@home)).to be_empty
  end

  it "--claude: the folders, the copies, the hook settings and the checks" do
    out, _err, status = run_install("--claude")

    expect(status).to be_success
    expect(out).not_to include("== Cursor ==")
    expect(out).to include(
      "mkdir -p ~/.claude/rules ~/.claude/skills ~/.claude/hooks",
      "cp -r skills/graph-mem-mcp-toolset ~/.claude/skills/",
      "cp docs/rules/graph_mem_user_rule.md ~/.claude/rules/graph-mem.md",
      "cp script/agent_hooks/graph_mem_session_start.sh ~/.claude/hooks/",
      "/memory", "/skills", "/context", '"alwaysLoad": true', "To leave it out"
    )
    blocks = json_blocks(out)
    expect(blocks.size).to eq(1)
    entry = blocks.first.dig("hooks", "SessionStart").first
    expect(entry).to eq("matcher" => "startup|resume|clear|compact",
                        "hooks" => [ { "type" => "command", "command" => "~/.claude/hooks/graph_mem_session_start.sh", "timeout" => 5 } ])
  end

  it "--cursor: the skill, the User Rules text and the hooks.json entry" do
    out, _err, status = run_install("--cursor")
    rule = File.read(File.join(root, "docs/rules/graph_mem_user_rule.md"))

    expect(status).to be_success
    expect(out).not_to include("== Claude Code ==")
    expect(out).to include("~/.cursor/skills/", "Customize > Rules", "cp script/agent_hooks/graph_mem_session_start_cursor.sh ~/.cursor/hooks/")
    rule.lines.map(&:strip).reject(&:empty?).each { |line| expect(out).to include(line) }
    expect(json_blocks(out)).to eq([ "version" => 1, "hooks" => { "sessionStart" => [ { "command" => "./hooks/graph_mem_session_start_cursor.sh" } ] } ])
  end

  it "--url: the Claude Code command's environment, and an edit of the copied script for Cursor" do
    out, _err, status = run_install("--url", "http://127.0.0.1:3031")

    expect(status).to be_success
    commands = json_blocks(out).map { |block| block.to_json[/"command":"([^"]+)"/, 1] }
    expect(commands).to eq([ "GRAPH_MEM_URL=http://127.0.0.1:3031 ~/.claude/hooks/graph_mem_session_start.sh",
                             "./hooks/graph_mem_session_start_cursor.sh" ])
    expect(out).to include("In the copied script, change http://localhost:3030 to http://127.0.0.1:3031")
    expect(run_install("--cursor").first).not_to include("In the copied script")
  end

  it "refuses a --url that isn't a plain http(s) base URL, and an unknown option" do
    [ [ "--url", 'http://synth-host"; true' ], [ "--url", "file:///synth" ], [ "--synth" ] ].each do |args|
      out, err, status = run_install(*args)

      expect([ out, status.exitstatus ]).to eq([ "", 2 ]), args.inspect
      expect(err).to include("Usage: bin/agent-install")
    end
  end

  it "names only repo files that exist, and no absolute path but the repo root's cd" do
    out, = run_install

    sources = out.scan(/^ +cp (?:-r )?(\S+) ~\//).flatten
    expect(sources).to include("skills/graph-mem-mcp-toolset", "skills/project-scan")
    sources.each { |path| expect(File.exist?(File.join(root, path))).to be(true), path }
    expect(out.scan(%r{(?<![~\w.])/[\w.-]+/[\w./-]*}).uniq - [ root ]).to all(start_with("/memory", "/skills", "/context", "/up"))
    expect(out).not_to include("mcpServers", "X-MCP-Client")
  end

  it "--help prints the usage" do
    out, _err, status = run_install("--help")

    expect(status).to be_success
    expect(out).to include("--claude", "--cursor", "--url URL", "writes nothing")
  end

  it "requires only the standard library and touches no home path in code" do
    source = File.readlines(script).grep_v(/^\s*#/).join

    expect(source.scan(/^require "([^"]+)"/).flatten).to contain_exactly("json", "optparse")
    expect(source).not_to match(/Dir\.home|ENV\["HOME"\]|File\.(write|open)|FileUtils|Net::HTTP|`/)
  end
end
