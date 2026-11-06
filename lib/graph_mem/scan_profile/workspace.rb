# frozen_string_literal: true

require "fileutils"
require "tmpdir"

module GraphMem
  module ScanProfile
    # The temp dirs `graph_mem:scan_profile` scans (F-3b): one fresh checkout per fixture repo under
    # one Dir.mktmpdir, removed when the block ends (also on error). A repo is the generated synth
    # repo or a clone of its pinned commit made by the fetcher (script/scan_profile/git_fetch.rb);
    # never a local folder. The manifest's `exclude` paths are deleted from the checkout before any
    # scan, so no glob can read them.
    #
    #   Workspace.open(fetcher: ScanProfileGitFetch) do |workspace|
    #     checkout = workspace.checkout(manifest.fetch("graph_mem"))
    #     checkout.files(["docs/*.md"]) # => ["docs/architecture.md", …] (relative, sorted)
    #   end
    class Workspace
      PREFIX = "graph_mem-scan-profile"

      # Raised when a repo can't be checked out at its pinned commit.
      class CheckoutError < StandardError; end

      # One checked-out repo.
      #
      # @!attribute repo [Manifest::Repo]
      # @!attribute root [String] the checkout's realpath, inside the workspace
      # @!attribute commit [String, nil] the checked-out SHA (nil for synth)
      Checkout = Data.define(:repo, :root, :commit) do
        # @param globs [Array<String>] the profile's globs
        # @return [Array<String>] the relative files the globs resolve to (see Workspace.resolved_files)
        def files(globs) = Workspace.resolved_files(root, globs, exclude: repo.exclude)
      end

      # @param fetcher [#call, nil] `call(url:, commit:, dir:)` clones the repo into `dir` and returns
      #   the checked-out SHA; nil when only synth is used
      # @yieldparam workspace [Workspace]
      # @return [Object] the block's value
      def self.open(fetcher: nil)
        dir = Dir.mktmpdir(PREFIX)
        yield new(dir, fetcher)
      ensure
        FileUtils.rm_rf(dir) if dir
      end

      # The files a scan with `globs` can read, before the scanner's caps: regular files only (a
      # symlink isn't followed, so nothing outside the checkout is counted or stat'ed), without the
      # manifest's excludes, ProjectScanner::EXCLUDED_FILE_GLOBS and hidden paths.
      #
      # @param root [String]
      # @param globs [Array<String>]
      # @param exclude [Array<String>]
      # @return [Array<String>] relative paths, sorted
      def self.resolved_files(root, globs, exclude: [])
        skipped = exclude + ProjectScanner::EXCLUDED_FILE_GLOBS
        Dir.glob(globs, base: root).uniq.select { |rel| File.lstat(File.join(root, rel)).file? }.reject do |rel|
          rel.split("/").any? { |segment| segment.start_with?(".") } ||
            skipped.any? { |glob| File.fnmatch?(glob, rel, File::FNM_PATHNAME | File::FNM_DOTMATCH) }
        end.sort
      end

      # @param dir [String] the workspace's temp dir
      # @param fetcher [#call, nil]
      def initialize(dir, fetcher)
        @dir = dir
        @fetcher = fetcher
      end

      # @param repo [Manifest::Repo]
      # @return [Checkout]
      # @raise [CheckoutError] when the clone fails or HEAD isn't the pinned commit
      def checkout(repo)
        root = File.join(@dir, repo.key)
        FileUtils.mkdir_p(root)
        commit = repo.synth? ? (Manifest.synthetic(repo.key).write(root) && nil) : fetch(repo, root)
        prune(root, repo.exclude)
        Checkout.new(repo: repo, root: File.realpath(root), commit: commit)
      end

      # Deletes a checkout once its scans are done (the workspace goes at the end anyway).
      #
      # @param checkout [Checkout]
      # @return [void]
      def remove(checkout)
        FileUtils.rm_rf(checkout.root) if checkout.root.start_with?("#{File.realpath(@dir)}/")
      end

      private

      def fetch(repo, root)
        raise CheckoutError, "no fetcher: only the synth repo can be used here" unless @fetcher

        head = @fetcher.call(url: repo.url, commit: repo.commit, dir: root).to_s.strip
        raise CheckoutError, "#{repo.key}: HEAD is #{head.first(12)}, not the pinned #{repo.commit.first(12)}" unless head == repo.commit

        head
      end

      def prune(root, globs)
        globs.each do |glob|
          Dir.glob(glob, File::FNM_DOTMATCH, base: root).each do |rel|
            FileUtils.rm_rf(File.join(root, rel)) unless %w[. ..].include?(File.basename(rel))
          end
        end
      end
    end
  end
end
