# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProjectScanFileFilter do
  it "never reads a scan root's top-level hidden entries, even via explicit globs" do
    with_scan_home(subfolders: "") do |home|
      FileUtils.mkdir_p(File.join(home, ".config", "gh"))
      File.write(File.join(home, ".config", "gh", "hosts.yml"), "oauth_token: synthetic")
      File.write(File.join(home, ".bash_history"), "synthetic")
      File.write(File.join(home, "notes.md"), "# notes")
      filter = described_class.new(home)

      kept = (filter.glob(".config/**/*") + filter.glob(".bash_history") + filter.glob("*.md"))
             .select { |path| File.file?(path) }.filter_map { |path| filter.kept_path(path) }

      expect(kept).to eq([ File.join(home, "notes.md") ])
      expect(filter.counters["skipped_denylisted"]).to eq(2)
    end
  end

  it "keeps a project's own dot-folders such as .github readable" do
    with_scan_project do |project|
      FileUtils.mkdir_p(File.join(project, ".github", "workflows"))
      File.write(File.join(project, ".github", "workflows", "ci.yml"), "on: push")
      filter = described_class.new(project)

      expect(filter.kept_path(File.join(project, ".github", "workflows", "ci.yml"))).to be_present
    end
  end

  it "returns the realpath it checked, so the read can't follow a different link" do
    with_scan_project do |project|
      File.write(File.join(project, "real.md"), "# real")
      File.symlink(File.join(project, "real.md"), File.join(project, "alias.md"))

      expect(described_class.new(project).kept_path(File.join(project, "alias.md"))).to eq(File.join(project, "real.md"))
    end
  end

  it "rejects '..' hidden in braces and globs metacharacters in the root's name literally" do
    Dir.mktmpdir("proj[1]") do |dir|
      root = File.realpath(dir)
      File.write(File.join(root, "a.md"), "# a")
      filter = described_class.new(root)

      expect(filter.invalid_glob(%w[docs/*.md {..,x}/secret])).to eq("{..,x}/secret")
      expect(filter.glob("*.md")).to eq([ File.join(root, "a.md") ])
    end
  end
end
