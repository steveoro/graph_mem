# frozen_string_literal: true

require "rails_helper"
require "json"
require "open3"
require "tmpdir"

# script/adoption_eval/run_eval.sh end to end, with fake binaries on PATH (the bin/up spec's pattern):
# claude, agent, curl and docker are shell stubs that log what they were asked, and a temp HOME,
# projects folder and eval folder hold only synth-* data. The fakes adopt graph_mem only when the
# lever the arm sets is really in place, so the runs prove the toggles apply and are undone.
RSpec.describe "script/adoption_eval/run_eval.sh" do
  let(:repo) { Rails.root.to_s }
  let(:script) { File.join(repo, "script/adoption_eval/run_eval.sh") }

  # The fake binaries, by name.
  def fakes = {
    # /up answers; an MCP initialize gets a version; every call's arguments are logged.
    "curl" => <<~'SH',
      printf '%s\n' "$*" >>"$FAKE_LOG/curl.args"
      [ -n "${FAKE_DOWN:-}" ] && exit 7
      case "$*" in *initialize*) printf '%s\n' '{"result":{"serverInfo":{"version":"9.9.9-synth"}}}' ;; esac
      exit 0
    SH
    # A stream-json session: graph_mem first only when the user rule is installed; a hook event
    # only when --settings names the graph_mem hook; a usage limit or a stray edit on request.
    "claude" => <<~'SH',
      [ "$1" = "--version" ] && { echo "9.9.9-synth (Claude Code)"; exit 0; }
      printf '%s\n' "$*" >>"$FAKE_LOG/claude.args"
      [ -n "${FAKE_SLEEP:-}" ] && sleep "$FAKE_SLEEP"
      settings=""; prev=""
      for arg in "$@"; do [ "$prev" = "--settings" ] && settings=$arg; prev=$arg; done
      echo '{"type":"system","subtype":"init","apiKeySource":"none"}'
      grep -q graph_mem_session_start "$settings" 2>/dev/null &&
        echo '{"type":"system","subtype":"hook_response","hook_name":"SessionStart:startup","hook_event":"SessionStart","stdout":"graph_mem synth-hook"}'
      if [ -n "${FAKE_LIMIT:-}" ]; then echo '{"type":"result","is_error":true,"result":"Claude AI usage limit reached|1"}'; exit 1; fi
      [ -n "${FAKE_TOUCH:-}" ] && touch "$FAKE_TOUCH"
      [ -f "$HOME/.claude/rules/graph-mem.md" ] &&
        echo '{"type":"assistant","message":{"id":"m1","content":[{"type":"tool_use","name":"mcp__graph_mem__get_context","input":{}}]}}'
      echo '{"type":"assistant","message":{"id":"m2","content":[{"type":"tool_use","name":"Edit","input":{"file_path":"synth"}}]}}'
      echo '{"type":"result","is_error":false,"num_turns":3,"usage":{"input_tokens":100},"total_cost_usd":0.01}'
    SH
    # The Cursor CLI: logged in unless FAKE_LOGGED_OUT; -p runs the sessionStart hooks of
    # ~/.cursor/hooks.json, keeps a copy of the CLI config it saw, and adopts when the hook spoke.
    "agent" => <<~'SH',
      case "$1" in
        --version) echo "2026.11.19-synth"; exit 0 ;;
        status) [ -n "${FAKE_LOGGED_OUT:-}" ] && echo "Not logged in" || echo "Logged in as synth"; exit 0 ;;
      esac
      cp "$HOME/.cursor/cli-config.json" "$FAKE_LOG/cursor-cli-seen.json"
      cp "$HOME/.cursor/mcp.json" "$FAKE_LOG/cursor-mcp-seen.json"
      said=""
      if [ -f "$HOME/.cursor/hooks.json" ]; then
        for cmd in $(jq -r '.hooks.sessionStart[]?.command' "$HOME/.cursor/hooks.json"); do
          said="$said$(cd "$HOME/.cursor" && sh "$cmd" 2>/dev/null)"
        done
      fi
      echo '{"type":"system","subtype":"init","apiKeySource":"login"}'
      case "$said" in *graph_mem*)
        echo '{"type":"tool_call","subtype":"started","tool_call":{"mcpToolCall":{"args":{"providerIdentifier":"graph_mem","toolName":"get_context"}},"toolCallId":"c1"}}' ;;
      esac
      echo '{"type":"tool_call","subtype":"started","tool_call":{"editToolCall":{"args":{"path":"synth"}},"toolCallId":"c2"}}'
      echo '{"type":"result","is_error":false,"usage":{"inputTokens":10}}'
    SH
    # docker compose: the settings reader answers false, the writer OK; every call is logged.
    "docker" => <<~'SH'
      printf '%s\n' "$*" | tr '\n' ' ' >>"$FAKE_LOG/docker.args" && echo >>"$FAKE_LOG/docker.args"
      case "$*" in
        *ADOPTION_EVAL_JSON*) echo 'ADOPTION_EVAL_JSON={"mcp_skills_enabled":false}' ;;
        *ADOPTION_EVAL_OK*) echo ADOPTION_EVAL_OK ;;
      esac
      exit 0
    SH
  }

  around do |example|
    Dir.mktmpdir("run-eval") do |root|
      @root = root
      %w[home projects eval bin log tmp].each { |dir| FileUtils.mkdir_p(File.join(root, dir)) }
      fakes.each do |name, body|
        File.write(File.join(root, "bin", name), "#!/bin/sh\n#{body}")
        File.chmod(0o755, File.join(root, "bin", name))
      end
      seed_home
      %w[goggles_admin2 fast-mcp synth-other].each { |name| git_repo(name) }
      example.run
    end
  end

  def path(*parts) = File.join(@root, *parts)

  def seed_home
    home = path("home")
    FileUtils.mkdir_p([ "#{home}/.claude/skills/graph-mem-mcp-toolset", "#{home}/.cursor" ])
    File.write("#{home}/.claude.json", JSON.generate(mcpServers: { graph_mem: { type: "http", url: "http://127.0.0.1:9/mcp", headers: { Authorization: "Bearer synth-token" } } }))
    File.write("#{home}/.claude/settings.json", JSON.generate(model: "synth-model"))
    File.write("#{home}/.claude/skills/graph-mem-mcp-toolset/SKILL.md", "synth-installed-skill\n")
    File.write("#{home}/.cursor/mcp.json", JSON.generate(mcpServers: { graph_mem: { url: "http://127.0.0.1:9/mcp", headers: { Authorization: "Bearer synth-token" } } }))
    File.write("#{home}/.cursor/cli-config.json", JSON.generate(permissions: { allow: [ "Shell(ls)" ], deny: [] }))
  end

  def git_repo(name)
    dir = path("projects", name)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "README.md"), "#{name} synth\n")
    git = "git -C #{dir} -c user.email=synth@example.invalid -c user.name=synth"
    system("#{git} init -q && #{git} add . && #{git} commit -qm synth && #{git} remote add origin https://example.invalid/#{name}.git", exception: true)
  end

  def env(extra = {})
    { "HOME" => path("home"), "PATH" => "#{path('bin')}:#{ENV.fetch('PATH')}", "TMPDIR" => path("tmp"),
      "ADOPTION_PROJECTS_DIR" => path("projects"), "ADOPTION_EVAL_DIR" => path("eval"), "FAKE_LOG" => path("log"),
      "ADOPTION_OLD_SKILL_REF" => "HEAD" }.merge(extra)
  end

  def run_eval(*args, extra: {})
    Bundler.with_unbundled_env { Open3.capture3(env(extra), "bash", script, *args, stdin_data: "") }
  end

  # Every entry under a folder (HOME by default): a symlink as its target, a file with its content.
  def home_tree(dir = path("home"))
    Dir.glob("**/*", File::FNM_DOTMATCH, base: dir).sort.to_h do |entry|
      full = File.join(dir, entry)
      value = if File.symlink?(full) then "-> #{File.readlink(full)}"
      elsif File.file?(full) then [ File.read(full), File.stat(full).mode.to_s(8) ]
      else :dir
      end
      [ entry, value ]
    end
  end

  def run_ids = Dir.children(path("eval", "runs")).sort
  def log(name) = File.exist?(path("log", name)) ? File.read(path("log", name)) : ""

  it "--dry-run lists the sessions and changes nothing" do
    before = home_tree
    out, err, status = run_eval("--suite", "screen", "--dry-run")

    expect(status).to be_success, err
    expect(out.lines.size).to eq(30)
    expect(err).to include("graph_mem 9.9.9-synth", "ALL+A: rule on, skill new, hook on, MCP alwaysload")
    expect(home_tree).to eq(before)
    expect(Dir.exist?(path("eval", "runs"))).to be(false)
    expect(Dir.children(path("projects"))).to contain_exactly("goggles_admin2", "fast-mcp", "synth-other")
    expect(Dir.children(path("tmp"))).to be_empty
  end

  it "runs the arms with their levers in place, writes the report, and puts HOME back exactly" do
    before = home_tree
    _out, err, status = run_eval("--suite", "custom", "--arms", "I,ALL", "--tasks", "T1", "--n", "1", "--yes")

    expect(status).to be_success, err
    id = run_ids.sole
    expect(id).to match(/\A\d{8}T\d{6}Z\z/)
    report = File.read(path("eval", "reports", "#{id}-report.md"))
    expect(report).to include("I    T1    1  0/1", "ALL  T1    1  1/1", "- **graph_mem:** 9.9.9-synth", "- **Model:** synth-model", "- **Auth:** none")
    expect(home_tree).to eq(before)
    expect(Dir.children(path("tmp"))).to be_empty
    expect(log("curl.args")).not_to include("synth-token")
    expect(log("claude.args")).not_to include("synth-token")

    clone = path("projects", "goggles_admin2-eval")
    expect(`git -C #{clone} remote get-url origin`.strip).to eq("https://example.invalid/goggles_admin2.git")
    expect(File.read(path("eval", "clones.lock"))).to include("goggles_admin2-eval #{`git -C #{clone} rev-parse HEAD`.strip}")
    run = JSON.parse(File.read(path("eval", "runs", id, "run.json")))
    expect(run["baseline"]).to include({ "path" => "~/.claude/skills/graph-mem-mcp-toolset", "exists" => true, "mentions_graph_mem" => false })
  end

  it "--resume keeps the finished sessions and runs only the missing ones" do
    run_eval("--suite", "custom", "--arms", "I", "--tasks", "T1", "--n", "1", "--yes")
    id = run_ids.sole
    File.write(path("eval", "runs", id, "run.json"), JSON.parse(File.read(path("eval", "runs", id, "run.json"))).merge("n" => 2).to_json)
    calls = log("claude.args").lines.size
    _out, err, status = run_eval("--resume", id, "--yes")

    expect(status).to be_success, err
    expect(log("claude.args").lines.size).to eq(calls + 1)
    expect(Dir.children(path("eval", "runs", id, "logs"))).to contain_exactly("I-T1-1.jsonl", "I-T1-2.jsonl")
  end

  it "stops on a usage limit with the resume hint, and still restores HOME" do
    before = home_tree
    _out, err, status = run_eval("--suite", "custom", "--arms", "ALL", "--tasks", "T1", "--n", "1", "--yes", extra: { "FAKE_LIMIT" => "1" })

    expect(status.exitstatus).to eq(75)
    expect(err).to include("usage limit", "--resume #{run_ids.sole}", "Restored 3 user-level path(s)")
    expect(home_tree).to eq(before)
    expect(Dir.children(path("eval", "runs", run_ids.sole, "logs"))).to eq([ "ALL-T1-1.jsonl.limited" ])
  end

  it "stops when a session changes another repo in the projects folder, and leaves the change" do
    stray = path("projects", "synth-other", "synth-stray.txt")
    _out, err, status = run_eval("--suite", "custom", "--arms", "I", "--tasks", "T1", "--n", "1", "--yes", extra: { "FAKE_TOUCH" => stray })

    expect(status.exitstatus).to eq(3)
    expect(err).to include("changed outside the scratch clones: synth-other")
    expect(File.exist?(stray)).to be(true)
  end

  it "--setting writes through the app container, restarts it, and restores the old value at the end" do
    _out, err, status = run_eval("--suite", "custom", "--arms", "I", "--tasks", "T1", "--n", "1", "--yes",
                                 "--setting", "mcp_skills_enabled=true")

    expect(status).to be_success, err
    steps = log("docker.args").lines.map do |line|
      if line.include?("restart app") then "restart"
      elsif line.include?("ADOPTION_EVAL_JSON") then "read"
      else "write #{line[/mcp_skills_enabled (\S+)/, 1]}"
      end
    end
    expect(steps).to eq([ "read", "write true", "restart", "write false", "restart" ])
    expect(JSON.parse(File.read(path("eval", "runs", run_ids.sole, "run.json")))["settings"])
      .to eq([ { "key" => "mcp_skills_enabled", "before" => "false", "after" => "true" } ])
  end

  it "runs the Cursor arms headless: readonly MCP, shell denied, the K2 hook fired, and ~/.cursor put back" do
    before = home_tree
    _out, err, status = run_eval("--suite", "custom", "--arms", "K0,K2", "--tasks", "T1", "--n", "1", "--yes")

    expect(status).to be_success, err
    expect(home_tree).to eq(before)
    seen = JSON.parse(log("cursor-cli-seen.json"))
    expect(seen.dig("permissions", "deny")).to include("Shell(*)", "Mcp(graph_mem:graph_write)")
    expect(seen.dig("permissions", "allow")).to include("Shell(ls)", "Mcp(graph_mem:get_context)")
    mcp = JSON.parse(log("cursor-mcp-seen.json")).dig("mcpServers", "graph_mem")
    expect(mcp).to include("url" => "http://127.0.0.1:9/mcp/readonly")
    expect(mcp["headers"]).to include("X-MCP-Client" => "adoption-eval-cursor", "Authorization" => "Bearer synth-token")
    dir = path("eval", "runs", run_ids.sole)
    expect(File.read(File.join(dir, "cursor-hooks.csv")).lines.drop(1)).to eq([ "K0,T1,1,0\n", "K2,T1,1,1\n" ])
    # The restored backup keeps no copy of the token-bearing files, only its markers.
    backup = Dir.children(File.join(dir, ".backup"))
    expect(backup).to all(satisfy { |name| name == "state" || name == "clones" || name.end_with?(".path", ".absent", ".newdir") })
    expect(Dir.glob(File.join(dir, "**", "*"), File::FNM_DOTMATCH).select { |file| File.file?(file) && File.read(file).include?("synth-token") }).to be_empty
    expect(File.read(File.join(dir, "report.md"))).to include("K0   T1    1  0/1", "K2   T1    1  1/1")
  end

  it "replaces symlinked config instead of writing through it, and puts the links back (dotfiles stay untouched)" do
    dotfiles = path("dotfiles")
    FileUtils.mkdir_p(dotfiles)
    home = path("home")
    File.write(File.join(dotfiles, "mcp.json"), File.read("#{home}/.cursor/mcp.json"))
    File.write(File.join(dotfiles, "cli-config.json"), File.read("#{home}/.cursor/cli-config.json"))
    File.write(File.join(dotfiles, "graph-mem.md"), "synth-own-rule\n")
    FileUtils.mkdir_p([ "#{home}/.claude/rules", "#{home}/.claude/hooks" ])
    { "#{home}/.cursor/mcp.json" => "mcp.json", "#{home}/.cursor/cli-config.json" => "cli-config.json",
      "#{home}/.claude/rules/graph-mem.md" => "graph-mem.md", "#{home}/.claude/hooks/graph_mem_session_start.sh" => "synth-missing" }
      .each { |link, target| FileUtils.rm_f(link) && File.symlink(File.join(dotfiles, target), link) }
    before = [ home_tree, home_tree(dotfiles) ]
    _out, err, status = run_eval("--suite", "custom", "--arms", "ALL,K0", "--tasks", "T1", "--n", "1", "--yes")

    expect(status).to be_success, err
    expect([ home_tree, home_tree(dotfiles) ]).to eq(before)
    expect(File.symlink?("#{home}/.claude/hooks/graph_mem_session_start.sh")).to be(true) # dangling, kept
  end

  it "keeps the .env token off every process list, and leaves no temp files when it stops early" do
    File.write(path("home", ".claude.json"), "{}")
    File.write(path("synth.env"), "GRAPH_MEM_MCP_TOKEN=synth-env-token\n")
    real_jq = `sh -c 'command -v jq'`.strip
    File.write(path("bin", "jq"), "#!/bin/sh\nprintf '%s\\n' \"$*\" >>\"$FAKE_LOG/jq.args\"\nexec #{real_jq} \"$@\"\n")
    File.chmod(0o755, path("bin", "jq"))
    _out, err, status = run_eval("--suite", "screen", "--dry-run", extra: { "ADOPTION_ENV_FILE" => path("synth.env") })

    expect(status).to be_success, err
    expect(log("jq.args") + log("curl.args")).not_to include("synth-env-token")
    expect(Dir.children(path("tmp"))).to be_empty

    _out, err, status = run_eval("--suite", "screen", "--yes", extra: { "ADOPTION_ENV_FILE" => path("synth.env"), "FAKE_DOWN" => "1" })
    expect(status).not_to be_success
    expect(err).to include("doesn't answer")
    expect(Dir.children(path("tmp"))).to be_empty
  end

  it "refuses to start while a killed run hasn't been restored, or while another run holds the lock" do
    FileUtils.mkdir_p(path("eval", "runs", "20260101T000000Z", ".backup"))
    File.write(path("eval", "runs", "20260101T000000Z", ".backup", "state"), "taken\n")
    _out, err, status = run_eval("--suite", "custom", "--arms", "I", "--tasks", "T1", "--n", "1", "--yes")
    expect(status).not_to be_success
    expect(err).to include("--restore 20260101T000000Z first")

    FileUtils.rm_rf(path("eval", "runs"))
    File.open(path("eval", ".lock"), File::CREAT | File::WRONLY) do |lock|
      lock.flock(File::LOCK_EX)
      _out, err, status = run_eval("--suite", "custom", "--arms", "I", "--tasks", "T1", "--n", "1", "--yes")
      expect(status).not_to be_success
      expect(err).to include("another run_eval.sh is running")
    end
  end

  it "--restore puts back what a killed run left: levers, settings and temp dirs" do
    backup = path("eval", "runs", "20260101T000000Z", ".backup")
    FileUtils.mkdir_p([ backup, path("home", ".claude", "rules"), path("tmp", "adoption-eval.synth") ])
    rule = path("home", ".claude", "rules", "graph-mem.md")
    File.write(rule, "synth-leftover-rule\n")
    File.write(File.join(backup, "p%.claude%rules%graph-mem.md.absent"), "#{rule}\n")
    File.write(File.join(backup, "p%.claude%rules%graph-mem.md.path"), "#{rule}\n")
    File.write(File.join(backup, "state"), "taken\n")
    File.write(File.join(backup, "settings"), "mcp_skills_enabled\nfalse\n")
    File.write(File.join(backup, "tmpdirs"), "#{path('tmp', 'adoption-eval.synth')}\n")
    _out, err, status = run_eval("--restore", "20260101T000000Z")

    expect(status).to be_success, err
    expect(File.exist?(rule)).to be(false)
    expect(Dir.children(path("tmp"))).to be_empty
    expect(log("docker.args")).to match(/runner .*ADOPTION_EVAL_OK.* mcp_skills_enabled false/m).and include("restart app")
    expect(File.read(File.join(backup, "state")).strip).to eq("restored")
    expect(File.exist?(File.join(backup, "settings"))).to be(false)
  end

  it "restores at once on a SIGTERM to the script alone, mid-session" do
    before = home_tree
    out_r, out_w = IO.pipe
    pid = Bundler.with_unbundled_env do
      Process.spawn(env("FAKE_SLEEP" => "30"), "bash", script, "--suite", "custom", "--arms", "ALL", "--tasks", "T1", "--n", "1", "--yes",
                    in: File::NULL, out: File::NULL, err: out_w)
    end
    out_w.close
    Timeout.timeout(20) { sleep 0.1 until log("claude.args").include?("-p") }
    started = Time.now
    Process.kill("TERM", pid)
    _, status = Timeout.timeout(15) { Process.wait2(pid) }

    expect(Time.now - started).to be < 10
    expect(status.exitstatus).to eq(130)
    expect(out_r.read).to include("Restored 3 user-level path(s)")
    expect(home_tree).to eq(before)
  end

  it "runs under LANG=C (the Ruby helpers read UTF-8 whatever the locale)" do
    _out, err, status = run_eval("--suite", "custom", "--arms", "ALL", "--tasks", "T1", "--n", "1", "--yes", extra: { "LANG" => "C", "LC_ALL" => "C" })

    expect(status).to be_success, err
  end

  it "asks for a Cursor login it can't do itself, and needs a terminal for it" do
    _out, err, status = run_eval("--suite", "custom", "--arms", "K0", "--tasks", "T1", "--n", "1", "--yes", extra: { "FAKE_LOGGED_OUT" => "1" })

    expect(status).not_to be_success
    expect(err).to include("isn't logged in", "needs a terminal")
  end

  it "refuses B0 and ALL-I, which need the 1.89.0 instructions, and unknown arms" do
    _out, err, status = run_eval("--suite", "custom", "--arms", "ALL-I", "--dry-run")
    expect(status).not_to be_success
    expect(err).to include("ALL-I needs the 1.89.0 instructions")
    expect(run_eval("--suite", "custom", "--arms", "synth-arm", "--dry-run")[1]).to include("unknown arm: synth-arm")
  end

  describe "the settings reader the script runs in the app container" do
    let(:reader) { File.read(script)[/SETTINGS_READ='(.*?)'$/m, 1] }

    # Runs the script's own fixed Ruby (no input reaches it but ARGV), as `rails runner` would.
    def read_settings(*keys)
      stub_const("ARGV", keys)
      buffer = StringIO.new
      $stdout = buffer
      eval(reader) # rubocop:disable Security/Eval
      buffer.string
    ensure
      $stdout = STDOUT
    end

    it "prints a feature flag's value" do
      expect(read_settings("mcp_skills_enabled")).to eq("ADOPTION_EVAL_JSON={\"mcp_skills_enabled\":false}\n")
    end

    it "refuses the access group, a cross-checked group, a field with its own validator, and unknown keys" do
      review_key = SettingsSchema.group(:review_policies).writable_keys.first
      { "enable_guest_access" => "access group", review_key => "review_policies group", "embedding_url" => "its own validator",
        "synth_unknown" => "unknown setting" }.each do |key, reason|
        expect { read_settings(key) }.to raise_error(SystemExit) { |error| expect(error.message).to include(reason) }
      end
    end
  end

  it "is valid bash, and shellcheck-clean when shellcheck is installed" do
    expect(system("bash", "-n", script)).to be(true)
    skip "shellcheck isn't installed" unless system("command -v shellcheck >/dev/null 2>&1")

    expect(system("shellcheck", "-x", script)).to be(true)
  end
end
