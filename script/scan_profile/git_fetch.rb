# frozen_string_literal: true

require "open3"

# Clones one pinned public repo for `bin/rails graph_mem:scan_profile` (F-3b) into a temp dir the
# profiler made (GraphMem::ScanProfile::Workspace). Operator tooling, like bin/: the Rails app
# itself never starts a process, and specs never run this (they use the synth repo).
#
# The clone ignores the user's and the system's git config (no URL rewrites, credential helpers or
# hooks), never prompts, and allows https only. Errors name the git step, never the temp path.
#
#   ScanProfileGitFetch.call(url: "https://github.com/dry-rb/dry-inflector.git",
#                            commit: "65f186bb68e5a40be8552dafc203d03cd35223a9", dir: "/tmp/…/dry-inflector")
#   # => "65f186bb68e5a40be8552dafc203d03cd35223a9"
module ScanProfileGitFetch
  # Raised when a git step fails.
  class Error < StandardError; end

  ENV_VARS = { "GIT_TERMINAL_PROMPT" => "0", "GIT_CONFIG_NOSYSTEM" => "1", "GIT_CONFIG_GLOBAL" => File::NULL,
               "GIT_ASKPASS" => "", "SSH_ASKPASS" => "" }.freeze
  CONFIG = [ "-c", "protocol.allow=never", "-c", "protocol.https.allow=always", "-c", "core.hooksPath=#{File::NULL}",
             "-c", "advice.detachedHead=false" ].freeze

  module_function

  # @param url [String] an https://github.com/… URL from the manifest
  # @param commit [String] the pinned SHA
  # @param dir [String] an empty dir to clone into
  # @return [String] the checked-out SHA (the caller compares it with the pin)
  # @raise [Error] when a git step fails (a missing commit included)
  def call(url:, commit:, dir:)
    raise Error, "only https://github.com/ URLs are cloned" unless url.start_with?("https://github.com/")

    git("clone", "--quiet", "--filter=blob:none", "--no-checkout", url, dir)
    git("-C", dir, "checkout", "--quiet", "--detach", commit)
    git("-C", dir, "rev-parse", "HEAD").strip
  end

  # @return [String] stdout
  def git(*args)
    out, err, status = Open3.capture3(ENV_VARS, "git", *CONFIG, *args)
    return out if status.success?

    step = args.first == "-C" ? args[2] : args.first
    raise Error, "git #{step} failed (exit #{status.exitstatus}): #{err.lines.last.to_s.strip.gsub(%r{/\S+}, '<path>')}"
  end
  private_class_method :git
end
