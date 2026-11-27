# frozen_string_literal: true

require "spec_helper"
require "active_support"
require "active_support/encrypted_configuration"
require "fileutils"
require "open3"
require "securerandom"
require "tmpdir"

# #206: bin/docker-entrypoint's preflight, run as `bin/docker-entrypoint ./bin/rails server` from a
# temp root holding a copy of the script, config/, storage/ and a fake bin/rails that logs its
# arguments and the length of the SECRET_KEY_BASE it got, never the value. Keys and credentials files
# are throwaway ones made here; a key is only ever compared, never printed.
RSpec.describe "bin/docker-entrypoint" do
  script = File.expand_path("../../bin/docker-entrypoint", __dir__)
  gemfile = File.expand_path("../../Gemfile", __dir__)
  generated_message = "secret_key_base: generated and kept in the storage volume (set SECRET_KEY_BASE in .env to choose your own)"

  around do |example|
    Dir.mktmpdir("docker_entrypoint") do |dir|
      @root = dir
      FileUtils.mkdir_p(%w[bin config storage].map { |sub| File.join(dir, sub) })
      FileUtils.cp(script, File.join(dir, "bin/docker-entrypoint"))
      File.write(File.join(dir, "bin/rails"), <<~'SH')
        #!/bin/bash
        echo "rails $* key_length=${#SECRET_KEY_BASE} key_set=${SECRET_KEY_BASE+yes}" >>rails.log
      SH
      File.chmod(0o755, File.join(dir, "bin/rails"))
      File.write(File.join(dir, "config/database.yml"), "production: {}\n")
      example.run
    end
  end

  def path(relative) = File.join(@root, relative)

  # Runs the entrypoint in the temp root with +env+ over the environment the suite started with,
  # minus any host SECRET_KEY_BASE or RAILS_MASTER_KEY. No jemalloc preload; BUNDLE_GEMFILE lets the
  # preflight's `bundle exec ruby` find the bundle.
  define_method(:run_entrypoint) do |env: {}, command: %w[./bin/rails server]|
    base = Bundler.with_unbundled_env { ENV.to_h }.except("SECRET_KEY_BASE", "RAILS_MASTER_KEY")
    base.merge!("LD_PRELOAD" => "", "BUNDLE_GEMFILE" => gemfile)
    Open3.capture3(base.merge(env), "bash", "bin/docker-entrypoint", *command, chdir: @root, unsetenv_others: true)
  end

  def rails_calls
    File.exist?(path("rails.log")) ? File.readlines(path("rails.log"), chomp: true) : []
  end

  def generated_key
    File.read(path("storage/secret_key_base")).strip
  end

  # Encrypts config/credentials.yml.enc with a new throwaway key and returns the key. The key file
  # used for writing is removed again, so the root has no config/master.key.
  def write_credentials
    key = ActiveSupport::EncryptedFile.generate_key
    File.write(path("throwaway.key"), key)
    ActiveSupport::EncryptedConfiguration.new(
      config_path: path("config/credentials.yml.enc"), key_path: path("throwaway.key"),
      env_key: "GRAPH_MEM_SPEC_UNSET_KEY", raise_if_missing_key: true
    ).write("secret_key_base: #{SecureRandom.hex(64)}\n")
    File.delete(path("throwaway.key"))
    key
  end

  describe "without SECRET_KEY_BASE and without a master key" do
    it "generates a 0600 key of 128 hex characters, gives it to every rails call and never prints it" do
      stdout, stderr, status = run_entrypoint(env: { "SECRET_KEY_BASE" => "", "RAILS_MASTER_KEY" => "" })

      expect(status).to be_success, stderr
      expect(generated_key.match?(/\A\h{128}\z/)).to be(true)
      expect(File.stat(path("storage/secret_key_base")).mode & 0o777).to eq(0o600)
      expect(Dir.children(path("storage"))).to eq([ "secret_key_base" ])
      expect(stdout.lines(chomp: true)).to eq([ generated_message ])
      expect(rails_calls).to eq([
        "rails db:prepare key_length=128 key_set=yes",
        "rails db:support:initialize key_length=128 key_set=yes",
        "rails server key_length=128 key_set=yes"
      ])
      expect((stdout + stderr).include?(generated_key)).to be(false)
    end

    it "reuses the key on later boots and says nothing" do
      run_entrypoint
      first = generated_key

      stdout, stderr, status = run_entrypoint

      expect(status).to be_success, stderr
      expect(stdout).to be_empty
      expect(generated_key == first).to be(true)
      expect(rails_calls.last).to eq("rails server key_length=128 key_set=yes")
    end
  end

  describe "with a key configured" do
    it "generates nothing when SECRET_KEY_BASE is set, and passes it on" do
      own = SecureRandom.hex(64)
      stdout, stderr, status = run_entrypoint(env: { "SECRET_KEY_BASE" => own })

      expect(status).to be_success, stderr
      expect(File.exist?(path("storage/secret_key_base"))).to be(false)
      expect(stdout).to be_empty
      expect(rails_calls.last).to eq("rails server key_length=128 key_set=yes")
      expect((stdout + stderr).include?(own)).to be(false)
    end

    it "generates nothing when RAILS_MASTER_KEY is set, and drops compose's empty SECRET_KEY_BASE" do
      master_key = write_credentials
      stdout, stderr, status = run_entrypoint(env: { "RAILS_MASTER_KEY" => master_key, "SECRET_KEY_BASE" => "" })

      expect(status).to be_success, stderr
      expect(File.exist?(path("storage/secret_key_base"))).to be(false)
      expect(stdout).to be_empty
      expect(rails_calls.last).to eq("rails server key_length=0 key_set=")
      expect((stdout + stderr).include?(master_key)).to be(false)
    end

    it "generates nothing when config/master.key exists" do
      master_key = write_credentials
      File.write(path("config/master.key"), master_key)
      _stdout, stderr, status = run_entrypoint

      expect(status).to be_success, stderr
      expect(File.exist?(path("storage/secret_key_base"))).to be(false)
      expect(rails_calls.last).to eq("rails server key_length=0 key_set=")
    end
  end

  it "runs no preflight for a command other than the server" do
    _stdout, stderr, status = run_entrypoint(command: %w[./bin/rails runner true])

    expect(status).to be_success, stderr
    expect(File.exist?(path("storage/secret_key_base"))).to be(false)
    expect(rails_calls).to eq([ "rails runner true key_length=0 key_set=" ])
  end

  it "is valid bash, and shellcheck-clean when shellcheck is installed" do
    _out, err, status = Open3.capture3("bash", "-n", script)
    expect(status).to be_success, err

    shellcheck = ENV.fetch("PATH").split(File::PATH_SEPARATOR).map { |dir| File.join(dir, "shellcheck") }.find { |file| File.executable?(file) }
    skip "shellcheck isn't installed" unless shellcheck
    out, _err, status = Open3.capture3(shellcheck, script)
    expect(status).to be_success, out
  end
end
