# frozen_string_literal: true

require "rails_helper"

# F-3b step S: the throwaway database and the run's isolation. These examples create and drop a
# real `<test db>_scan_profile` database on the test server, so they run outside a transaction;
# they write nothing to the test database itself.
RSpec.describe GraphMem::ScanProfile::Sandbox do
  self.use_transactional_tests = false

  let(:base_config) { ActiveRecord::Base.connection_pool.db_config }
  let(:target) { "#{base_config.database}_scan_profile" }
  let(:admin) { described_class::AdminRecord }

  def server
    admin.establish_connection(base_config.configuration_hash.except(:url, :database).merge(database: nil))
    yield admin.connection
  ensure
    admin.remove_connection
  end

  def database?(name)
    server { |connection| connection.select_value("SELECT 1 FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = #{connection.quote(name)}").present? }
  end

  def drop(name)
    server { |connection| connection.execute("DROP DATABASE IF EXISTS #{connection.quote_table_name(name)}") }
  end

  def row_counts
    connection = ActiveRecord::Base.connection
    connection.tables.sort.to_h { |table| [ table, connection.select_value("SELECT COUNT(*) FROM #{connection.quote_table_name(table)}").to_i ] }
  end

  # The database of every statement that writes, while the block runs: [database or nil (server level), sql].
  def writes
    list = []
    callback = lambda do |*, payload|
      sql = payload[:sql].to_s
      list << [ payload[:connection]&.pool&.db_config&.database, sql ] if sql.match?(/\A\s*(INSERT|UPDATE|DELETE|REPLACE|CREATE|DROP|ALTER|TRUNCATE)\b/i)
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    list
  end

  after { drop(target) if database?(target) }

  describe "refusals, before any database is touched" do
    before { allow(admin).to receive(:establish_connection).and_call_original }

    {
      "production" => [ { env: "production" }, /never runs in production/ ],
      "a name without the suffix" => [ { target: "graph_mem_test_copy" }, /must be named <name>_scan_profile/ ],
      "the bare suffix" => [ { target: "_scan_profile" }, /must be named/ ],
      "a name that isn't an identifier" => [ { target: "synth`; DROP DATABASE x; -- _scan_profile" }, /must be named/ ]
    }.each do |label, (options, message)|
      it "refuses #{label}" do
        sandbox = described_class.new(base_config: base_config, **options)

        expect { sandbox.run { raise "never reached" } }.to raise_error(described_class::Refused, message)
        expect(admin).not_to have_received(:establish_connection)
      end
    end

    it "refuses an adapter other than MariaDB/MySQL" do
      sqlite = ActiveRecord::DatabaseConfigurations::HashConfig.new("test", "primary", adapter: "sqlite3", database: "synth.sqlite3")

      expect { described_class.new(base_config: sqlite).run { nil } }.to raise_error(described_class::Refused, /needs MariaDB/)
    end

    it "refuses a configured database whose own name ends with the suffix" do
      config = ActiveRecord::DatabaseConfigurations::HashConfig.new("test", "primary", base_config.configuration_hash.merge(database: target))

      expect { described_class.new(base_config: config, target: target).run { nil } }.to raise_error(described_class::Refused, /is the configured database/)
    end
  end

  it "refuses an existing database it didn't make, and leaves it alone" do
    server { |connection| connection.execute("CREATE DATABASE #{connection.quote_table_name(target)}") }

    expect { described_class.new(base_config: base_config).run { raise "never reached" } }
      .to raise_error(described_class::Refused, /exists and wasn't made by graph_mem:scan_profile/)
    expect(database?(target)).to be(true)
  end

  it "creates, loads, marks and drops the throwaway database; every write goes there; the test database is untouched" do
    before_counts = row_counts
    cache = Rails.cache
    adapter = ActiveJob::Base.queue_adapter
    seen = {}

    recorded = writes do
      described_class.new(base_config: base_config).run do |sandbox|
        seen[:database] = ActiveRecord::Base.connection.current_database
        seen[:tables] = ActiveRecord::Base.connection.tables.sort
        seen[:marker] = ActiveRecord::Base.connection.select_value("SELECT `value` FROM ar_internal_metadata WHERE `key` = 'graph_mem_scan_profile'")
        seen[:adapter] = ActiveJob::Base.queue_adapter.class.name
        seen[:cache_isolated] = !Rails.cache.equal?(cache)
        sandbox.configure!(chain: "ollama", settings: { "summary_model" => "synth-model" })
        sandbox.project!(name: "Gadget Project")
        GarbageCollectionJob.perform_later
        seen[:enqueued] = sandbox.enqueued
        seen[:summary_on] = AppSettings.llm_summarization_enabled?
        sandbox.reset_graph!
        seen[:after_reset] = MemoryEntity.count
        seen[:model_kept] = AppSettings.summary_model
      end
    end

    expect(seen[:database]).to eq(target)
    expect(seen[:tables]).to eq(ActiveRecord::Base.connection.tables.sort)
    expect(seen[:marker]).to eq(GraphMem::VERSION)
    expect(seen).to include(adapter: "ActiveJob::QueueAdapters::TestAdapter", cache_isolated: true, summary_on: true,
                            enqueued: { "GarbageCollectionJob" => 1 }, after_reset: 0, model_kept: "synth-model")
    expect(recorded).not_to be_empty
    expect(recorded.reject { |database, sql| database == target || (database.nil? && sql.include?("`#{target}`")) }).to be_empty
    expect(database?(target)).to be(false)
    expect(ActiveRecord::Base.connection.current_database).to eq(base_config.database)
    expect(Rails.cache).to be(cache)
    expect(ActiveJob::Base.queue_adapter).to be(adapter)
    expect(row_counts).to eq(before_counts)
  end

  it "keeps the database with keep_db, and the next run drops that leftover and starts clean" do
    described_class.new(base_config: base_config, keep_db: true).run { |sandbox| sandbox.project!(name: "Gadget Project") }
    expect(database?(target)).to be(true)

    entities = described_class.new(base_config: base_config).run { MemoryEntity.count }

    expect(entities).to eq(0)
    expect(database?(target)).to be(false)
  end

  it "drops the database when the block fails" do
    expect { described_class.new(base_config: base_config).run { raise ArgumentError, "synthetic failure" } }.to raise_error(ArgumentError)
    expect(database?(target)).to be(false)
    expect(ActiveRecord::Base.connection.current_database).to eq(base_config.database)
  end

  it "makes projects the cloud gate refuses, so a cloud chain sends nothing" do
    Dir.mktmpdir("sandbox-spec") do |dir|
      root = File.realpath(dir)
      allowed = described_class.new(base_config: base_config).run do |sandbox|
        sandbox.configure!(chain: "agent_cli")
        sandbox.project!(name: "Gadget Project")
        Llm::CloudGate.allowed?(Llm::Scope.for_scan(project_root: root, project_name: "Gadget Project"))
      end

      expect(allowed).to be(false)
    end
  end

  it "embeds new facts only when the embedding endpoint is on this machine (1.76.0)" do
    seen = {}
    { "http://127.0.0.1:11434" => :loopback, "http://[::1]:11434" => :ipv6, "https://embeddings.example:443" => :remote }.each do |url, label|
      allow(EmbeddingConfig).to receive(:resolved_config).and_return({ url: url, model: "synth-embed", provider: "ollama", dims: 768 })
      described_class.new(base_config: base_config).run do |sandbox|
        seen[label] = [ sandbox.embeddings, EmbeddingService.inline_embeddings_suppressed? ]
      end
    end

    expect(seen).to eq(loopback: [ "local", false ], ipv6: [ "local", false ], remote: [ "off", true ])
    expect(EmbeddingService.inline_embeddings_suppressed?).to be(false)
  end
end
