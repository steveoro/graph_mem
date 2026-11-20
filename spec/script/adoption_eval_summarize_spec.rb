# frozen_string_literal: true

require "spec_helper"
require "open3"
require "tmpdir"

# Auto-adoption A6 (1.90.0): script/adoption_eval/summarize.rb over hand-written synthetic logs in
# spec/fixtures/adoption_eval (docs/plans/done/auto-adoption-tests.md §1 and §5):
#   B0-T1-1  hook fired, ToolSearch for a graph_mem tool, get_context and search before the first Edit
#   B0-T1-2  no graph_mem call before a Write
#   B0-T2-1  a graph_mem search only after a MultiEdit: not adopted
#   R-T1-1   the skill, a search before an Edit in the same message, a denied graph_write (counted once)
#   H-T1-1   a hook event, a malformed line, no edit, no result (turns, tokens and cost are n/a)
#   K2-T1-1  a Cursor CLI stream: a tool lookup, an MCP get_context, a denied shell call, an edit, a
#            rejected graph_write
#   synth-notes  not named <arm>-<task>-<run>.jsonl: skipped
RSpec.describe "script/adoption_eval/summarize.rb" do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:script) { File.join(root, "script/adoption_eval/summarize.rb") }
  let(:logs) { Dir[File.join(root, "spec/fixtures/adoption_eval/*.jsonl")].sort }

  # Outside the bundle, as a user runs it (bundle exec's RUBYOPT makes RubyGems warn on CI).
  def unbundled(&) = Bundler.with_unbundled_env(&)

  def summarize(*args)
    out, err, status = unbundled { Open3.capture3("ruby", script, *args) }
    expect([ err, status.exitstatus ]).to eq([ "", 0 ])
    out
  end

  def csv_rows(out)
    header, *rows = out.lines.map(&:chomp).reject { |line| line.start_with?("#") }
    rows.to_h { |line| values = header.split(",").zip(line.split(",")).to_h; [ values.values_at("arm", "task").join("/"), values ] }
  end

  it "counts each arm, and each arm and task, from the Claude Code and Cursor streams" do
    rows = csv_rows(summarize(*logs, "--csv"))

    expect(rows.keys).to eq(%w[B0/all B0/T1 B0/T2 H/all H/T1 K2/all K2/T1 R/all R/T1])
    expect(rows["B0/all"]).to include("n" => "3", "adopted" => "1", "ctx_before_edit" => "1", "median_first_gm_turn" => "2",
                                      "mean_gm_calls" => "1.0", "toolsearch_gm" => "1", "hook_fired" => "1",
                                      "median_turns" => "5", "median_tokens" => "2000", "median_cost" => "0.1000")
    expect(rows["B0/T1"]).to include("n" => "2", "adopted" => "1", "median_tokens" => "2135")
    expect(rows["B0/T2"]).to include("adopted" => "0", "ctx_before_edit" => "0", "median_first_gm_turn" => "2")
    expect(rows["R/T1"]).to include("adopted" => "1", "ctx_before_edit" => "0", "skill_used" => "1", "persist_attempts" => "1",
                                    "mean_gm_calls" => "2.0", "median_tokens" => "300")
    expect(rows["H/T1"]).to include("adopted" => "1", "hook_fired" => "1", "median_first_gm_turn" => "1",
                                    "median_turns" => "n/a", "median_tokens" => "n/a", "median_cost" => "n/a")
    # The Cursor CLI shape as checked on agent 2026.11.19: a tool lookup, get_context, a denied shell call,
    # an edit, then a rejected graph_write; camelCase usage and no num_turns.
    expect(rows["K2/T1"]).to include("adopted" => "1", "ctx_before_edit" => "1", "toolsearch_gm" => "1", "mean_gm_calls" => "2.0",
                                     "persist_attempts" => "1", "median_tokens" => "6928", "median_turns" => "n/a")
  end

  it "prints an aligned table with rates as count/n, and a footer of skipped lines and files" do
    lines = summarize(*logs).lines.map(&:rstrip)

    expect(lines.first.split).to eq(%w[arm task n adopted ctx_before_edit median_first_gm_turn mean_gm_calls skill_used
                                       toolsearch_gm persist_attempts hook_fired median_turns median_tokens median_cost])
    expect(lines[1].split).to eq(%w[B0 all 3 1/3 1/3 2 1.0 0/3 1/3 0 1/3 5 2000 0.1000])
    expect(lines.last).to eq("6 sessions, 1 malformed lines skipped, 1 files skipped (not <arm>-<task>-<run>.jsonl)")
  end

  it "prints whole tokens past a million, not scientific notation" do
    Dir.mktmpdir("adoption-eval") do |dir|
      log = File.join(dir, "B0-T1-1.jsonl")
      File.write(log, %({"type":"result","num_turns":25,"usage":{"input_tokens":34567,"cache_read_input_tokens":1200000},"total_cost_usd":1.5}\n))

      expect(csv_rows(summarize(log, "--csv"))["B0/all"]["median_tokens"]).to eq("1234567")
    end
  end

  it "prints counts and tool-free labels only: no prompt, text, tool input, result or hook output" do
    out = summarize(*logs) + summarize(*logs, "--csv")

    expect(out).not_to match(/synth-(secret|hook|app|alpha|late|model|session)|graph_write|get_context|search\b/)
  end

  it "is stdlib only and read-only" do
    source = File.readlines(script).grep_v(/^\s*#/).join

    expect(source.scan(/^require "([^"]+)"/).flatten).to contain_exactly("json", "optparse")
    expect(source).not_to match(/File\.(write|open)|FileUtils|IO\.write|Net::HTTP|Socket|`|system\(|Rails/)
  end

  it "prints the usage and fails without logs" do
    _out, err, status = unbundled { Open3.capture3("ruby", script) }

    expect(status.exitstatus).to eq(1)
    expect(err).to include("Usage: ruby script/adoption_eval/summarize.rb")
  end

  describe "AdoptionEval::Session (used by run_eval.sh and report.rb)" do
    before { require File.expand_path("../../script/adoption_eval/summarize.rb", __dir__) }

    def session(lines) = AdoptionEval::Session.new("synth-arm", "T1", lines.map(&:to_json))

    it "notes a ToolSearch for a write tool, completeness and a usage-limit stop" do
      search = { type: "assistant", message: { id: "m1", content: [ { type: "tool_use", name: "ToolSearch", input: { query: "select:mcp__graph_mem__graph_write" } } ] } }
      limited = { type: "result", is_error: true, result: "Claude AI usage limit reached|1700000000" }
      done = { type: "result", is_error: false, num_turns: 3 }

      expect(session([ search, done ]).metrics).to include(write_search: true, complete: true, limited: false, capped: false)
      expect(session([ search ]).metrics).to include(write_search: true, complete: false, limited: false, capped: false)
      expect(session([ limited ]).metrics).to include(complete: true, limited: true, capped: false)
      expect(session([ { type: "result", is_error: true, result: "synth-other-error" } ]).metrics[:limited]).to be(false)

      # The shape Claude Code 2.1.328 wrote when the 5-hour window ran out (1.92.0): each sign alone counts.
      capped_result = { type: "result", subtype: "success", is_error: true, num_turns: 1, usage: { input_tokens: 0 } }
      rejected = { type: "rate_limit_event", rate_limit_info: { status: "rejected" } }
      allowed = { type: "rate_limit_event", rate_limit_info: { status: "allowed" } }
      expect(session([ capped_result.merge(api_error_status: 429) ]).metrics[:limited]).to be(true)
      expect(session([ capped_result.merge(result: "You've hit your 5-hour limit · resets 9:00pm (synth)") ]).metrics[:limited]).to be(true)
      expect(session([ rejected, capped_result ]).metrics[:limited]).to be(true)
      expect(session([ allowed, capped_result ]).metrics[:limited]).to be(false)
      expect(session([ rejected, done ]).metrics[:limited]).to be(false)
      expect(session([ { type: "result", subtype: "error_max_turns", num_turns: 25 } ]).metrics).to include(complete: true, capped: true, limited: false)
    end

    it "builds from a file named <arm>-<task>-<run>.jsonl, and refuses other names" do
      expect(AdoptionEval::Session.from_file(logs.find { |path| path.end_with?("R-T1-1.jsonl") })).to have_attributes(arm: "R", task: "T1")
      expect(AdoptionEval::Session.from_file(logs.find { |path| path.end_with?("synth-notes.jsonl") })).to be_nil
    end
  end
end
