# frozen_string_literal: true

require "rails_helper"

RSpec.describe ScanRootPolicy do
  def resolve(path) = described_class.resolve(path)

  def mkdir(*parts)
    File.join(*parts).tap { |dir| FileUtils.mkdir_p(dir) }
  end

  describe ".resolve inside a native home" do
    it "accepts a folder inside an allowed subfolder, and the subfolder itself, returning the realpath" do
      with_scan_home do |home|
        project = mkdir(home, "Projects", "alpha")

        expect(resolve(project)).to have_attributes(ok: true, code: :ok, path: project, root: home)
        expect(resolve(File.join(home, "Projects"))).to have_attributes(ok: true, path: File.join(home, "Projects"))
      end
    end

    it "rejects a sibling folder that only shares the root's prefix" do
      with_scan_home do |home|
        sibling = mkdir("#{home}2", "Projects")

        expect(resolve(sibling).code).to eq(:not_mounted)
      ensure
        FileUtils.rm_rf("#{home}2")
      end
    end

    it "rejects '..', NUL bytes, over-long input and blank input" do
      with_scan_home do |home|
        expect(resolve("#{home}/Projects/../..").code).to eq(:invalid)
        expect(resolve("foo/../..").code).to eq(:invalid)
        expect(resolve("#{home}/Projects/a\0b").code).to eq(:invalid)
        expect(resolve("/#{'x' * 5000}").code).to eq(:invalid)
        expect(resolve("  ").code).to eq(:blank)
      end
    end

    it "resolves '~/…' and a relative path with one root, and refuses a relative path with two" do
      with_scan_home do |home|
        project = mkdir(home, "Projects", "a")

        expect(resolve("~/Projects/a").path).to eq(project)
        expect(resolve("a").path).to eq(project)

        mkdir(home, "work")
        write_scan_subfolders_raw("Projects, work")
        expect(resolve("a").code).to eq(:invalid)
      end
    end

    it "denies hidden and protected folders at any depth" do
      with_scan_home(subfolders: "") do |home|
        %w[.ssh Projects/.secret/x .config/y snap/x Library/x].each do |relative|
          expect(resolve(mkdir(home, relative)).code).to eq(:denied), relative
        end
      end
    end

    it "follows symlinks: outside the root is refused, into a hidden folder is denied, inside the filter is fine" do
      with_scan_home do |home|
        Dir.mktmpdir("outside") do |outside|
          File.symlink(outside, File.join(home, "Projects", "escape"))
          File.symlink(mkdir(home, ".ssh"), File.join(home, "Projects", "keys"))
          target = mkdir(home, "Projects", "real")
          File.symlink(target, File.join(home, "Projects", "alias"))

          expect(resolve(File.join(home, "Projects", "escape")).code).to eq(:outside_roots)
          expect(resolve(File.join(home, "Projects", "keys")).code).to eq(:denied)
          expect(resolve(File.join(home, "Projects", "alias")).path).to eq(target)
        end
      end
    end

    it "explains how to widen the filter for a folder outside it" do
      with_scan_home do |home|
        result = resolve(mkdir(home, "Other", "x"))

        expect(result.code).to eq(:outside_filter)
        expect(result.message).to include("outside the scan filter (Projects)", "Add Other in Settings › Project scans")
      end
    end

    it "allows every filter entry, and the whole home with a warning when the filter is blank" do
      with_scan_home(subfolders: "Projects, work/clients") do |home|
        expect(resolve(mkdir(home, "work", "clients", "acme"))).to be_ok

        write_scan_subfolders_raw("")
        result = resolve(mkdir(home, "Misc"))
        expect(result).to be_ok
        expect(result.warnings).to include(:whole_home_allowed)
      end
    end

    it "applies a filter change written by another process at once, with no reload" do
      with_scan_home do |home|
        other = mkdir(home, "Other")
        expect(resolve(other).code).to eq(:outside_filter)

        AppSettings.connection.execute(
          AppSettings.sanitize_sql([ "UPDATE #{AppSettings.table_name} SET value = ? WHERE var = ?",
                                     YAML.dump("Projects, Other"), "project_scan_subfolders" ])
        )

        expect(resolve(other)).to be_ok
      end
    end

    it "reports a file, a missing path and an unreadable folder distinctly" do
      with_scan_home do |home|
        file = File.join(home, "Projects", "notes.txt").tap { |path| File.write(path, "x") }
        expect(resolve(file).code).to eq(:not_directory)
        expect(resolve(File.join(home, "Projects", "missing"))).to have_attributes(code: :not_found)
        expect(resolve(File.join(home, "Projects", "missing")).message).to include("its parent #{home}/Projects exists")

        next if Process.uid.zero?

        locked = mkdir(home, "Projects", "locked")
        File.chmod(0o000, locked)
        expect(resolve(locked).code).to eq(:not_readable)
      ensure
        File.chmod(0o755, locked) if locked && File.exist?(locked)
      end
    end
  end

  describe "switches and container mode" do
    let(:ro_mount) { "36 25 0:31 / %{home} ro,relatime master:1 - ext4 /dev/sda1 rw\n" }
    let(:rw_mount) { "36 25 0:31 / %{home} rw,relatime master:1 - ext4 /dev/sda1 rw\n" }

    it "is disabled by GRAPH_MEM_SCANS=off" do
      with_scan_home do |home|
        ENV["GRAPH_MEM_SCANS"] = "off"

        expect(resolve(File.join(home, "Projects")).code).to eq(:disabled)
      end
    end

    it "is not configured in a container with no root, or with a root that isn't a mount point" do
      ENV["GRAPH_MEM_IN_CONTAINER"] = "1"
      ENV.delete("GRAPH_MEM_SCAN_ROOTS")
      expect(resolve("/home/steve/Projects/x").code).to eq(:not_configured)

      with_scan_home(container: true, mountinfo: "36 25 0:31 / /other ro - ext4 /dev/sda1 rw\n") do |home|
        result = resolve(File.join(home, "Projects"))
        expect(result.code).to eq(:not_configured)
        expect(result.message).to include(ScanRootPolicy::COMPOSE_VOLUME_LINE)
      end
    end

    it "accepts a read-only mount quietly and warns about a read-write one" do
      with_scan_home(container: true, mountinfo: ro_mount) do |home|
        expect(resolve(File.join(home, "Projects"))).to have_attributes(ok: true, warnings: [])
      end
      with_scan_home(container: true, mountinfo: rw_mount) do |home|
        expect(resolve(File.join(home, "Projects")).warnings).to include(:mounted_read_write)
        expect(described_class.status[:warnings]).to include(:mounted_read_write)
      end
    end

    it "rejects hard roots that overlap the system, the app or the container user's home" do
      ENV["GRAPH_MEM_IN_CONTAINER"] = "1"
      [ "/", "/rails", Rails.root.to_s, "/home/rails", "/usr/local" ].each do |root|
        ENV["GRAPH_MEM_SCAN_ROOTS"] = root
        expect(described_class.hard_roots.first[:error]).to be_present, root
      end
      ENV["GRAPH_MEM_SCAN_ROOTS"] = Rails.root.to_s
      expect(described_class.hard_roots.first[:error]).to include("overlaps")
      expect(described_class.valid_hard_roots).to be_empty
    end

    it "keeps the native default (home) usable although the app lives inside it" do
      ENV.delete("GRAPH_MEM_SCAN_ROOTS")

      expect(described_class.hard_roots.first).to include(path: File.realpath(Dir.home), error: nil)
    end
  end

  describe ".status" do
    it "lists roots, filter entries with their errors, and the denylist" do
      with_scan_home(subfolders: "Projects, ../x, .ssh") do |home|
        status = described_class.status

        expect(status).to include(enabled: true, mode: "native", allowed_roots: [ File.join(home, "Projects") ])
        expect(status[:subfolders].map { |entry| entry[:error] }).to eq([ nil, "contains '..'", "is inside a hidden or protected folder (.ssh)" ])
        expect(status[:denylist][:files]).to include(".env", "*.pem")
      end
    end
  end

  describe "PR #111 review" do
    it "refuses a home folder as one project, including '~'" do
      with_scan_home(subfolders: "") do |home|
        allow(Dir).to receive(:home).and_return(home)

        expect(resolve(home)).to have_attributes(code: :whole_root)
        expect(resolve(home).message).to include("is a home folder; pick a project folder inside it")
        expect(resolve("~").code).to eq(:whole_root)
      end
    end

    it "accepts a scan root that isn't a home as one project (per-project mounts, GRAPH_MEM_SCAN_ROOTS=/tmp/foo)" do
      with_scan_home(subfolders: "") do |root|
        expect(resolve(root)).to have_attributes(ok: true, path: root)
      end
    end

    it "treats /root and folders directly under /home or /Users as homes, and refuses /home as a root" do
      expect(described_class.home_folder?("/root")).to be(true)
      expect(described_class.home_folder?("/home/someone")).to be(true)
      expect(described_class.home_folder?("/Users/someone")).to be(true)
      expect(described_class.home_folder?("/home/someone/Projects")).to be(false)

      ENV["GRAPH_MEM_SCAN_ROOTS"] = "/home"
      expect(described_class.hard_roots.first[:error]).to include("holds every user's home") if File.directory?("/home")
    end

    it "matches protected home-level names only as the first segment below the root" do
      with_scan_home(subfolders: "") do |home|
        expect(resolve(mkdir(home, "Projects", "library"))).to be_ok
        expect(resolve(mkdir(home, "Projects", "snap"))).to be_ok
        expect(resolve(mkdir(home, "Snap", "x")).code).to eq(:denied)
        expect(ScanRootPolicy::Subfolders.parse("Projects/library, Mail").map { |entry| entry[:error] })
          .to eq([ nil, "is inside a hidden or protected folder (Mail)" ])
      end
    end

    it "allows nothing when every stored filter entry is invalid (fails closed)" do
      with_scan_home do |home|
        project = mkdir(home, "Projects", "alpha")
        write_scan_subfolders_raw(".ssh, ../x")

        expect(described_class.allowed_roots).to eq([])
        expect(resolve(project).code).to eq(:outside_filter)
      end
    end

    it "matches protected root folder names regardless of case" do
      with_scan_home(subfolders: "") do |home|
        expect(resolve(mkdir(home, "library", "x")).code).to eq(:denied)
      end
    end
  end
end
