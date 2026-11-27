# frozen_string_literal: true

require "rails_helper"

# #206: the key bin/docker-entrypoint generates is used only when no other key source is set. Throwaway
# keys in a temp root; a plain Hash stands in for ENV, so the real environment is never touched.
RSpec.describe GraphMem::GeneratedSecretKey do
  let(:generated) { SecureRandom.hex(64) }
  let(:config) { ActiveSupport::OrderedOptions.new }

  around do |example|
    Dir.mktmpdir("generated_secret_key") do |dir|
      @root = Pathname(dir)
      FileUtils.mkdir_p([ @root.join("config"), @root.join("storage") ])
      example.run
    end
  end

  def write_generated_key(content = "#{generated}\n")
    @root.join(described_class::PATH).write(content)
  end

  def apply(env)
    described_class.apply(config, env: env, root: @root)
  end

  it "keeps the path in step with bin/docker-entrypoint" do
    entrypoint = Rails.root.join("bin/docker-entrypoint").read

    expect(entrypoint).to include("GENERATED_KEY_FILE=#{described_class::PATH}\n")
  end

  describe ".apply" do
    it "uses the generated key when SECRET_KEY_BASE and RAILS_MASTER_KEY are empty and there is no config/master.key" do
      write_generated_key
      env = { "SECRET_KEY_BASE" => "", "RAILS_MASTER_KEY" => "" }

      expect(apply(env)).to be(true)
      expect(config.secret_key_base == generated).to be(true)
      expect(env.key?("SECRET_KEY_BASE")).to be(false)
    end

    it "drops compose's empty SECRET_KEY_BASE but leaves the key to the credentials when RAILS_MASTER_KEY is set" do
      write_generated_key
      master_key = SecureRandom.hex(16)
      env = { "SECRET_KEY_BASE" => "", "RAILS_MASTER_KEY" => master_key }

      expect(apply(env)).to be(false)
      expect(config.secret_key_base).to be_nil
      expect(env.keys).to eq([ "RAILS_MASTER_KEY" ])
      expect(env["RAILS_MASTER_KEY"] == master_key).to be(true)
    end

    it "leaves the key to the credentials when config/master.key exists" do
      write_generated_key
      @root.join("config/master.key").write(SecureRandom.hex(16))

      expect(apply({})).to be(false)
      expect(config.secret_key_base).to be_nil
    end

    it "keeps a SECRET_KEY_BASE that is set and ignores the generated file" do
      write_generated_key
      own = SecureRandom.hex(64)
      env = { "SECRET_KEY_BASE" => own }

      expect(apply(env)).to be(false)
      expect(config.secret_key_base).to be_nil
      expect(env["SECRET_KEY_BASE"] == own).to be(true)
    end

    it "does nothing before a key was generated, or when the file is empty" do
      expect(apply({})).to be(false)

      write_generated_key("\n")
      expect(apply({})).to be(false)
      expect(config.secret_key_base).to be_nil
    end
  end

  describe ".read" do
    it "returns the key without its trailing newline" do
      write_generated_key

      expect(described_class.read(env: {}, root: @root) == generated).to be(true)
    end
  end
end
