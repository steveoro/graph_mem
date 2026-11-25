# frozen_string_literal: true

require "rails_helper"

# `graph_mem:vector_bench` (step 1 of docs/plans/mariadb-vector-search-plan.md): the scratch
# database's guards, and one tiny run end to end. The run creates and drops a real
# `<test db>_vector_bench` database on the test server, so these examples run outside a transaction;
# they write nothing to the test database itself.
RSpec.describe GraphMem::VectorBench::Runner do
  self.use_transactional_tests = false

  let(:base_config) { ActiveRecord::Base.connection_pool.db_config }
  let(:target) { "#{base_config.database}_vector_bench" }
  let(:sandbox_class) { GraphMem::VectorBench::Sandbox }

  def server
    sandbox_class::AdminRecord.establish_connection(base_config.configuration_hash.except(:url, :database).merge(database: nil))
    yield sandbox_class::AdminRecord.connection
  ensure
    sandbox_class::AdminRecord.remove_connection
  end

  def database?(name)
    server { |connection| connection.select_value("SELECT 1 FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = #{connection.quote(name)}").present? }
  end

  after { server { |connection| connection.execute("DROP DATABASE IF EXISTS #{connection.quote_table_name(target)}") } }

  describe "the scratch database's refusals, before the server is touched" do
    before { allow(sandbox_class::AdminRecord).to receive(:establish_connection).and_call_original }

    {
      "production" => [ { env: "production" }, /never runs in production/ ],
      "a name without the suffix" => [ { target: "graph_mem_test_copy" }, /must be named <name>_vector_bench/ ],
      "a name that isn't an identifier" => [ { target: "synth`; DROP DATABASE x; -- _vector_bench" }, /must be named/ ],
      "a database of config/database.yml" => [ { target: "synth_vector_bench", configured: %w[synth_vector_bench] }, /is a database of config/ ],
      "an adapter other than MariaDB/MySQL" => [
        { base_config: ActiveRecord::DatabaseConfigurations::HashConfig.new("test", "primary", adapter: "sqlite3", database: "synth.sqlite3") },
        /needs MariaDB/
      ]
    }.each do |label, (options, message)|
      it "refuses #{label}" do
        expect { sandbox_class.new(**options).run { raise "never reached" } }.to raise_error(sandbox_class::Refused, message)
        expect(sandbox_class::AdminRecord).not_to have_received(:establish_connection)
      end
    end
  end

  it "refuses an existing database it didn't make, and leaves it alone" do
    server { |connection| connection.execute("CREATE DATABASE #{connection.quote_table_name(target)}") }

    expect { sandbox_class.new(target: target).run { raise "never reached" } }.to raise_error(sandbox_class::Refused, /wasn't made by graph_mem:vector_bench/)
    expect(database?(target)).to be(true)
  end

  it "seeds, measures and reports in the scratch database, drops it, and leaves the test database alone" do
    counts = VectorIndexFixture.row_counts
    options = described_class::Options.from_env("ROWS" => "60", "CLUSTERS" => "3", "PROBES" => "2", "WRITES" => "2", "K" => "5", "DB" => target)

    report = described_class.new(options, log: StringIO.new).call

    expect(report).to start_with("## Vector bench: 60 entities, 60 observations")
    expect(report.scan(/^### .+$/)).to eq([ "### Search latency", "### Recall@5 of the raw index shape against exact",
                                            "### Write cost (2 single-row writes per table)" ])
    expect(report).to include("| Entity search | raw index shape, `ORDER BY d LIMIT 40` | yes |", "| memory_observations | INSERT (no vector) | no |")
    expect(database?(target)).to be(false)
    expect(ActiveRecord::Base.connection.current_database).to eq(base_config.database)
    expect(VectorIndexFixture.row_counts).to eq(counts)
  end

  it "reads its knobs from ENV and refuses a value that isn't a positive integer" do
    expect(described_class::Options.from_env({})).to have_attributes(rows: 10_000, observations: 10_000, clusters: 50, probes: 20, writes: 500, k: 10)
    expect { described_class::Options.from_env("ROWS" => "0") }.to raise_error(ArgumentError, /ROWS must be positive/)
    expect { described_class::Options.from_env("WRITES" => "many") }.to raise_error(ArgumentError)
  end
end
