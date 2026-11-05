# frozen_string_literal: true

require "rails_helper"

# F-3b step F: the fixture manifest (script/scan_profile/repos.yml) accepts public, pinned,
# licensed GitHub repos only, and the synth repo is always there.
RSpec.describe GraphMem::ScanProfile::Manifest do
  subject(:manifest) { described_class.load }

  let(:entry) do
    { "url" => "https://github.com/synth-owner/synth-gadget.git", "commit" => "a" * 40, "license" => "MIT",
      "profiles" => { "docs" => "default", "code" => [ "lib/**/*.rb" ] } }
  end

  def build(repos, caps: { "max_total_input_bytes" => 65_536, "max_files" => 20 })
    described_class.new({ "first_run_caps" => caps, "repos" => repos })
  end

  it "lists synth first, then the pinned repos of the plan, and nothing else" do
    expect(manifest.keys).to eq(%w[synth graph_mem goggles_db goggles_api dry-inflector])
  end

  it "pins graph_mem at the v1.72.0 commit and excludes its planning history, images, fixtures, harness and changelog" do
    repo = manifest.fetch("graph_mem")

    expect(repo.url).to eq("https://github.com/steveoro/graph_mem.git")
    expect(repo.commit).to eq("7769d582be520882fad7eda373d4ecf9b09c423c")
    expect(repo.exclude).to eq(%w[docs/plans/**/* docs/images/**/* spec/fixtures/**/* script/mcp_compat/**/* CHANGELOG.md])
    expect(repo.globs("docs")).not_to include("docs/**/*.md")
    expect(repo.globs("code")).to eq(%w[app/services/*.rb app/models/*.rb app/tools/*.rb])
  end

  it "pins the other repos by full SHA, with a license, and resolves `default` to the scanner's globs" do
    expect(manifest.fetch("goggles_db").commit).to eq("d14e6d705d985e6182b73e3ba69bae33a24be8f2")
    expect(manifest.fetch("goggles_api").commit).to eq("e95fa8a9b44ad3f2b91d673d6e62bf5a6575edae")
    expect(manifest.fetch("dry-inflector").commit).to eq("65f186bb68e5a40be8552dafc203d03cd35223a9")
    expect(manifest.keys.drop(1).map { |key| manifest.fetch(key).license }).to all(be_present)
    expect(manifest.fetch("goggles_api").globs("docs")).to eq(ProjectScanner::DEFAULT_FILE_GLOBS)
  end

  it "gives the first-run caps, the scanner's own with FULL=1, and always the scanner's own to goggles_db" do
    scanner_caps = { max_total_input_bytes: nil, max_files: nil }

    expect(manifest.caps(manifest.fetch("goggles_api"), full: false)).to eq(max_total_input_bytes: 65_536, max_files: 20)
    expect(manifest.caps(manifest.fetch("goggles_api"), full: true)).to eq(scanner_caps)
    expect(manifest.caps(manifest.fetch("goggles_db"), full: false)).to eq(scanner_caps)
  end

  it "refuses a key that isn't in the manifest or synth" do
    expect { manifest.fetch("synth-private") }.to raise_error(described_class::Error, /unknown repo "synth-private"/)
  end

  it "accepts a public https GitHub repo pinned by a full SHA" do
    expect(build({ "synth-gadget" => entry }).fetch("synth-gadget").project_name).to eq("synth-gadget")
  end

  {
    "a local folder" => { "url" => "/path/to/graph_mem" },
    "a file URL" => { "url" => "file:///path/to/graph_mem.git" },
    "an ssh URL" => { "url" => "git@github.com:synth-owner/synth-gadget.git" },
    "another host" => { "url" => "https://gitlab.example/synth-owner/synth-gadget.git" },
    "a branch instead of a commit" => { "commit" => "main" },
    "a short SHA" => { "commit" => "a" * 12 },
    "no license" => { "license" => "" },
    "a missing profile" => { "profiles" => { "docs" => "default" } },
    "an absolute glob" => { "profiles" => { "docs" => "default", "code" => [ "/etc/*" ] } },
    "a parent glob" => { "profiles" => { "docs" => "default", "code" => [ "../*.rb" ] } }
  }.each do |label, change|
    it "refuses #{label}" do
      expect { build({ "synth-gadget" => entry.merge(change) }) }.to raise_error(described_class::Error)
    end
  end

  it "refuses a manifest entry named synth" do
    expect { build({ "synth" => entry }) }.to raise_error(described_class::Error, /key/)
  end
end
