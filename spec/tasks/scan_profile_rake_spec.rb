# frozen_string_literal: true

require "rails_helper"
require "open3"
require Rails.root.join("script/scan_profile/fake_ollama").to_s

# F-3b acceptance: `bin/rails graph_mem:scan_profile REPOS=synth` runs end to end in its own
# process (test env, so the throwaway database is <test db>_scan_profile) with the stub backend:
# script/scan_profile/fake_ollama.rb on a loopback port, answering from the synth repo. No model,
# no network, no clone.
RSpec.describe "bin/rails graph_mem:scan_profile" do
  let(:fake) { ScanProfileFakeOllama.start(0) }

  after { fake.stop }

  def task(env)
    Dir.mktmpdir("scan-profile-rake") do |reports|
      base = { "RAILS_ENV" => "test", "OLLAMA_URL" => "http://127.0.0.1:9", "SUMMARY_URL" => fake.url, "REPORT_DIR" => reports }
      out, status = Open3.capture2e(base.merge(env), Rails.root.join("bin/rails").to_s, "graph_mem:scan_profile", chdir: Rails.root.to_s)
      yield out, status, Dir.glob(File.join(reports, "*", "report.json")).map { |path| JSON.parse(File.read(path)) }
    end
  end

  it "profiles the synth repo with the stub backend and drops the throwaway database" do
    task("REPOS" => "synth", "PROFILE" => "docs", "RESCAN" => "0") do |out, status, reports|
      expect(status).to be_success, out
      expect(out).to include("[scan_profile] throwaway database #{ActiveRecord::Base.connection_db_config.database}_scan_profile")
      expect(reports.sole["runs"].sole).to include("repo" => "synth", "profile" => "docs")
      expect(reports.sole["runs"].sole["scans"]["initial"]).to include("fallback" => false, "parts_failed" => 0)
      expect(reports.sole["backend"]).to include("database_kept" => false, "left_machine" => false)
      expect(fake.requests).to be_positive
    end
  end

  it "refuses a repo that isn't in the manifest, before touching any database" do
    task("REPOS" => "synth,/path/to/graph_mem") do |out, status, reports|
      expect(status).not_to be_success
      expect(out).to include('graph_mem:scan_profile: REPOS: unknown repo "/path/to/graph_mem"')
      expect(reports).to be_empty
      expect(fake.requests).to eq(0)
    end
  end
end
