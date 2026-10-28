# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"

# UI-2a A5: bin/up's LAN detection, run as `bin/up --print` from a temp copy with fake ip/route/
# ifconfig/ipconfig/hostname/scutil/uname binaries on a PATH that holds nothing else but a few
# standard tools. Synthetic addresses and names only; the real .env is never read.
RSpec.describe "bin/up" do
  script = File.expand_path("../../bin/up", __dir__)
  standard_tools = %w[bash sed awk grep tr head tail dirname cat]

  linux = {
    "uname" => "echo Linux",
    "hostname" => "echo Synth-Box",
    "ip" => <<~SH
      case "$*" in
        "-4 route get 1.1.1.1") echo "1.1.1.1 via 10.9.8.1 dev eth0 src 10.9.8.18 uid 1000"; echo "    cache" ;;
        "-o -4 addr show dev eth0") echo "2: eth0    inet 10.9.8.18/24 brd 10.9.8.255 scope global dynamic eth0\\       valid_lft 86000sec" ;;
        *) exit 1 ;;
      esac
    SH
  }
  macos = {
    "uname" => "echo Darwin",
    "scutil" => '[ "$*" = "--get LocalHostName" ] && echo Synth-Mac',
    "route" => '[ "$*" = "-n get default" ] && printf "   route to: default\n    gateway: 172.20.0.1\n  interface: en0\n"',
    "ipconfig" => '[ "$*" = "getifaddr en0" ] && echo 172.20.1.5',
    "ifconfig" => "printf 'en0: flags=8863<UP> mtu 1500\\n\\tinet6 fe80::1%%en0 prefixlen 64\\n\\tinet 172.20.1.5 netmask 0xffff0000 broadcast 172.20.255.255\\n'"
  }

  around do |example|
    Dir.mktmpdir("bin_up") do |dir|
      @root = dir
      example.run
    end
  end

  def which(tool)
    ENV.fetch("PATH").split(File::PATH_SEPARATOR).map { |dir| File.join(dir, tool) }.find { |path| File.executable?(path) }
  end

  # Copies bin/up into the temp root and runs `bin/up --print` there with only +fakes+ and the
  # standard tools on PATH, and only +env+ in the environment.
  define_method(:run_up) do |fakes, env: {}, dotenv: nil, args: [ "--print" ]|
    FileUtils.mkdir_p(File.join(@root, "bin"))
    FileUtils.cp(script, File.join(@root, "bin", "up"))
    File.write(File.join(@root, ".env"), dotenv) if dotenv
    path = File.join(@root, "path")
    FileUtils.mkdir_p(path)
    standard_tools.each { |tool| File.symlink(which(tool), File.join(path, tool)) }
    fakes.each do |name, body|
      File.write(File.join(path, name), "#!/bin/bash\n#{body}\n")
      File.chmod(0o755, File.join(path, name))
    end
    Open3.capture3({ "PATH" => path }.merge(env), File.join(path, "bash"), File.join(@root, "bin", "up"), *args,
                   unsetenv_others: true, chdir: @root)
  end

  it "detects the Linux host name, address and subnet, keeping loopback and the Docker bridge range" do
    stdout, stderr, status = run_up(linux)

    expect(status).to be_success
    expect(stderr).to be_empty
    expect(stdout).to include("GRAPH_MEM_MCP_ALLOWED_HOSTS=synth-box,synth-box.local,10.9.8.18 (detected)")
    expect(stdout).to include("GRAPH_MEM_MCP_ALLOWED_IPS=127.0.0.0/8,::1,172.16.0.0/12,10.9.8.0/24 (detected)")
    expect(stdout).to include("GRAPH_MEM_MCP_ALLOWED_ORIGINS unset")
  end

  it "detects the same on macOS from route, ipconfig and ifconfig" do
    stdout, _stderr, status = run_up(macos)

    expect(status).to be_success
    expect(stdout).to include("GRAPH_MEM_MCP_ALLOWED_HOSTS=synth-mac,synth-mac.local,172.20.1.5 (detected)")
    expect(stdout).to include("GRAPH_MEM_MCP_ALLOWED_IPS=127.0.0.0/8,::1,172.16.0.0/12,172.20.0.0/16 (detected)")
  end

  it "passes a value from the environment through unchanged" do
    stdout, = run_up(linux, env: { "GRAPH_MEM_MCP_ALLOWED_HOSTS" => "env-host.test" })

    expect(stdout).to include("GRAPH_MEM_MCP_ALLOWED_HOSTS=env-host.test (ENV)")
    expect(stdout).to include("10.9.8.0/24 (detected)")
  end

  it "lets a .env line win over detection, but not a commented one" do
    dotenv = "# GRAPH_MEM_MCP_ALLOWED_HOSTS=commented.test\nGRAPH_MEM_MCP_ALLOWED_IPS=\"127.0.0.0/8,::1,10.9.0.0/16\"\n"
    stdout, = run_up(linux, dotenv: dotenv)

    expect(stdout).to include("GRAPH_MEM_MCP_ALLOWED_IPS=127.0.0.0/8,::1,10.9.0.0/16 (.env)")
    expect(stdout).to include("GRAPH_MEM_MCP_ALLOWED_HOSTS=synth-box,synth-box.local,10.9.8.18 (detected)")
  end

  it "prefers the environment over .env" do
    stdout, = run_up(linux, env: { "GRAPH_MEM_MCP_ALLOWED_IPS" => "127.0.0.1" }, dotenv: "GRAPH_MEM_MCP_ALLOWED_IPS=10.9.0.0/16\n")

    expect(stdout).to include("GRAPH_MEM_MCP_ALLOWED_IPS=127.0.0.1 (ENV)")
  end

  it "leaves the IPs to the defaults for a public address, but still sets the hosts" do
    public_linux = linux.merge("ip" => linux["ip"].gsub("10.9.8.18", "192.0.2.18").gsub("10.9.8", "192.0.2"))
    stdout, _stderr, status = run_up(public_linux)

    expect(status).to be_success
    expect(stdout).to include("GRAPH_MEM_MCP_ALLOWED_HOSTS=synth-box,synth-box.local,192.0.2.18 (detected)")
    expect(stdout).to include("GRAPH_MEM_MCP_ALLOWED_IPS unset (built-in default: 192.0.2.18 is not a private address)")
  end

  it "falls back to the built-in defaults with one stderr line when every tool is missing" do
    stdout, stderr, status = run_up({})

    expect(status).to be_success
    expect(stderr.lines.size).to eq(1)
    expect(stderr).to start_with("bin/up: LAN detection failed:").and include("using the built-in defaults")
    expect(stdout.lines.size).to eq(3)
    expect(stdout.lines).to all(match(/\AGRAPH_MEM_MCP_ALLOWED_\w+ unset \(built-in default: /))
  end

  it "falls back when the ip output can't be parsed" do
    _stdout, stderr, status = run_up(linux.merge("ip" => "echo garbage"))

    expect(status).to be_success
    expect(stderr).to include("LAN detection failed: unexpected ip route output")
  end

  it "runs docker compose up -d with the compose args and the detected values exported" do
    fake_docker = 'echo "docker $*"; echo "hosts=${GRAPH_MEM_MCP_ALLOWED_HOSTS-<unset>}"; echo "ips=${GRAPH_MEM_MCP_ALLOWED_IPS-<unset>}"'
    stdout, stderr, status = run_up(linux.merge("docker" => fake_docker), args: [ "--build" ],
                                    dotenv: "GRAPH_MEM_MCP_ALLOWED_IPS=10.9.0.0/16\n", env: { "GRAPH_MEM_MCP_ALLOWED_IPS" => "" })

    expect(status).to be_success
    expect(stdout.lines.map(&:chomp)).to eq([ "docker compose up -d --build", "hosts=synth-box,synth-box.local,10.9.8.18", "ips=<unset>" ])
    expect(stderr).to include("GRAPH_MEM_MCP_ALLOWED_IPS=10.9.0.0/16 (.env)")
  end

  it "documents --print in --help" do
    stdout, _stderr, status = run_up({}, args: [ "--help" ])

    expect(status).to be_success
    expect(stdout).to include("Usage: bin/up [--print] [compose args...]")
  end

  it "is valid bash, and shellcheck-clean when shellcheck is installed" do
    _out, err, status = Open3.capture3("bash", "-n", script)
    expect(status).to be_success, err

    shellcheck = which("shellcheck")
    skip "shellcheck isn't installed" unless shellcheck
    out, _err, status = Open3.capture3(shellcheck, script)
    expect(status).to be_success, out
  end
end
