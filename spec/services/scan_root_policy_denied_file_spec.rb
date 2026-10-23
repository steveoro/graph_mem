# frozen_string_literal: true

require "rails_helper"

RSpec.describe ScanRootPolicy, ".denied_file?" do
  denied = %w[.env .env.local config/master.key id_ed25519 .git/config deploy.pem terraform.tfstate
              certs/server.key .aws/credentials secrets/credentials.yml .netrc
              Deploy.PEM .ENV ID_RSA .SSH/config .Git/HEAD .bash_history .zsh_history .pgpass .my.cnf vpn/home.ovpn]
  allowed = %w[app/models/x.rb .github/workflows/ci.yml README.md config/database.yml docs/keys.md]

  around do |example|
    Dir.mktmpdir("denied_files") do |dir|
      @root = File.realpath(dir)
      (denied + allowed).each do |relative|
        path = File.join(@root, relative)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "synthetic")
      end
      example.run
    end
  end

  denied.each do |relative|
    it("denies #{relative}") { expect(described_class.denied_file?(@root, File.join(@root, relative))).to be(true) }
  end

  allowed.each do |relative|
    it("allows #{relative}") { expect(described_class.denied_file?(@root, File.join(@root, relative))).to be(false) }
  end

  it "denies a harmless-looking link that resolves to a secret file" do
    File.symlink(File.join(@root, ".env"), File.join(@root, "settings.txt"))

    expect(described_class.denied_file?(@root, File.join(@root, "settings.txt"))).to be(true)
  end

  it "can't be widened by any setting value" do
    [ "", ".", ".env", "*", "Projects, .git" ].each do |value|
      AppSettings.project_scan_subfolders = value

      expect(described_class.denied_file?(@root, File.join(@root, ".env"))).to be(true), value.inspect
    end
  end
end
