# frozen_string_literal: true

# F-3b: profile a project scan, by hand only, on pinned open-source repos or the synthetic repo, in
# a throwaway database. See docs/scan_profiling.md. Never scheduled, enqueued or exposed elsewhere.
namespace :graph_mem do
  desc "Profile a project scan on pinned open-source repos / the synth repo in a throwaway DB " \
       "(REPOS=… PROFILE=docs|code RESCAN=0 FULL=1 KEEP_DB=1 BACKEND=… ALLOW_CLOUD=1 SWEEP=… SETTINGS=… DB=… REPORT_DIR=…)"
  task scan_profile: :environment do
    require Rails.root.join("script/scan_profile/git_fetch").to_s

    manifest = GraphMem::ScanProfile::Manifest.load
    options = GraphMem::ScanProfile::Options.parse(ENV.to_h, manifest: manifest)
    fetcher = options.repos == [ GraphMem::ScanProfile::SynthRepo::KEY ] ? nil : ScanProfileGitFetch
    report = GraphMem::ScanProfile::Runner.new(options: options, manifest: manifest, fetcher: fetcher).call
    dir = Pathname.new(report.dir)
    puts "[scan_profile] report: #{dir.to_s.start_with?(Rails.root.to_s) ? dir.relative_path_from(Rails.root) : dir}/report.{md,json}"
  rescue GraphMem::ScanProfile::Options::Error, GraphMem::ScanProfile::Manifest::Error, GraphMem::ScanProfile::Sandbox::Refused => e
    abort "graph_mem:scan_profile: #{e.message}"
  end
end
