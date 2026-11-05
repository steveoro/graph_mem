# frozen_string_literal: true

require "rails_helper"

# F-3b step F: checkouts live in one temp dir, removed at the end; a repo is the synth repo or a
# clone of its pinned commit (here a fake fetcher writing a synthetic tree with graph_mem's
# layout, never the real repo or this checkout), and the excluded paths never reach a scan.
RSpec.describe GraphMem::ScanProfile::Workspace do
  let(:manifest) { GraphMem::ScanProfile::Manifest.load }
  let(:graph_mem) { manifest.fetch("graph_mem") }

  # A synthetic tree laid out like graph_mem at its tag: one file in each included and excluded place.
  let(:layout) do
    %w[README.md Gemfile CHANGELOG.md AGENTS.md docs/architecture.md docs/summarization.md docs/operator/projects.md
       docs/guides/setup.md docs/plans/f3b-synth-plan.md docs/plans/ideas/synth.md docs/images/ui/synth.md
       spec/fixtures/mcp/synth.md script/mcp_compat/README.md app/services/synth_widget_service.rb
       app/models/synth_widget.rb app/tools/synth_tool.rb app/services/nested/deep.rb .github/workflows/synth.md]
  end
  let(:calls) { [] }
  let(:fetcher) do
    lambda do |url:, commit:, dir:|
      calls << { url: url, commit: commit, dir: dir }
      layout.each do |rel|
        FileUtils.mkdir_p(File.join(dir, File.dirname(rel)))
        File.write(File.join(dir, rel), "# synthetic #{rel}\n")
      end
      commit
    end
  end

  it "clones graph_mem from its public URL at the pinned tag commit into the workspace's temp dir" do
    described_class.open(fetcher: fetcher) { |workspace| workspace.checkout(graph_mem) }

    expect(calls.sole).to include(url: "https://github.com/steveoro/graph_mem.git", commit: "7769d582be520882fad7eda373d4ecf9b09c423c")
    expect(calls.sole[:dir]).to start_with(File.join(Dir.tmpdir, described_class::PREFIX))
    expect(calls.sole[:dir]).not_to start_with(Rails.root.to_s)
  end

  it "leaves the excluded paths out of graph_mem's resolved file lists, and deletes them from the clone" do
    described_class.open(fetcher: fetcher) do |workspace|
      checkout = workspace.checkout(graph_mem)
      docs = checkout.files(graph_mem.globs("docs"))
      code = checkout.files(graph_mem.globs("code"))

      expect(docs).to eq(%w[Gemfile README.md docs/architecture.md docs/guides/setup.md docs/operator/projects.md docs/summarization.md])
      expect(code).to eq(%w[app/models/synth_widget.rb app/services/synth_widget_service.rb app/tools/synth_tool.rb])
      everything = checkout.files([ "**/*" ])
      expect(everything).not_to include(a_string_matching(%r{\A(docs/plans|docs/images|spec/fixtures|script/mcp_compat)/}))
      expect(everything).not_to include("CHANGELOG.md")
      expect(File).not_to exist(File.join(checkout.root, "docs/plans/f3b-synth-plan.md"))
      expect(File).not_to exist(File.join(checkout.root, "CHANGELOG.md"))
    end
  end

  it "keeps hidden paths and the scanner's own excluded globs out of a resolved list" do
    Dir.mktmpdir("workspace-spec") do |root|
      %w[.github/synth.md docs/plans/synth.md docs/synth.md].each do |rel|
        FileUtils.mkdir_p(File.join(root, File.dirname(rel)))
        File.write(File.join(root, rel), "synthetic\n")
      end

      expect(described_class.resolved_files(root, [ "**/*", ".github/*.md" ])).to eq(%w[docs/synth.md])
    end
  end

  it "doesn't count a symlink in a resolved list, so nothing outside the checkout is stat'ed" do
    Dir.mktmpdir("workspace-spec") do |root|
      Dir.mktmpdir("workspace-outside") do |outside|
        File.write(File.join(outside, "synth_secret.md"), "outside the checkout\n")
        FileUtils.mkdir_p(File.join(root, "docs"))
        File.write(File.join(root, "docs/synth.md"), "synthetic\n")
        File.symlink(File.join(outside, "synth_secret.md"), File.join(root, "docs/linked.md"))
        File.symlink(outside, File.join(root, "docs/linked_dir"))

        expect(described_class.resolved_files(root, [ "docs/**/*" ])).to eq(%w[docs/synth.md])
      end
    end
  end

  it "refuses a checkout whose HEAD isn't the pinned commit" do
    moved = ->(url:, commit:, dir:) { "b" * 40 }

    described_class.open(fetcher: moved) do |workspace|
      expect { workspace.checkout(graph_mem) }.to raise_error(described_class::CheckoutError, /not the pinned 7769d582be52/)
    end
  end

  it "refuses a git repo without a fetcher (synth only)" do
    described_class.open do |workspace|
      expect { workspace.checkout(graph_mem) }.to raise_error(described_class::CheckoutError, /no fetcher/)
    end
  end

  it "writes the synth repo without a fetcher, and removes the temp dir at the end, also on error" do
    root = nil

    expect do
      described_class.open do |workspace|
        root = workspace.checkout(manifest.fetch("synth")).root
        expect(File).to exist(File.join(root, "README.md"))
        raise ArgumentError, "synthetic failure"
      end
    end.to raise_error(ArgumentError)
    expect(File).not_to exist(File.dirname(root))
  end
end
