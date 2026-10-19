# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmbeddingIndexManager do
  let(:conn) { ActiveRecord::Base.connection }
  let(:dims) { 4 }
  let(:zero_vec_function) { "VEC_FromText(concat('[',repeat('0,',3),'0]'))" }

  before do |example|
    next if example.metadata[:real_db]

    allow(ActiveRecord::Base).to receive(:connection).and_return(conn)
    allow(EmbeddingConfig).to receive(:resolved_config).and_return(
      url: "http://localhost:11434",
      model: "test",
      provider: "ollama",
      dims: dims
    )
    allow(EmbeddingIndexStatus).to receive(:indexes).and_return(
      memory_entities: true,
      memory_observations: true
    )
    allow(MemoryEntity).to receive_message_chain(:missing_embedding, :count).and_return(0)
    allow(MemoryObservation).to receive_message_chain(:missing_embedding, :count).and_return(0)
  end

  describe ".add_indexes! (synthetic DB states)" do
    it "raises when embedding columns are missing" do
      allow(conn).to receive(:column_exists?).and_return(true)
      allow(conn).to receive(:column_exists?).with(:memory_observations, :embedding).and_return(false)

      expect {
        described_class.add_indexes!
      }.to raise_error(EmbeddingIndexManager::PrecheckError, /don't exist/)
    end

    it "raises when NULL embeddings remain" do
      allow(conn).to receive(:column_exists?).and_return(true)
      allow(MemoryEntity).to receive_message_chain(:missing_embedding, :count).and_return(2)

      expect {
        described_class.add_indexes!
      }.to raise_error(EmbeddingIndexManager::PrecheckError, /NULL embeddings/)
    end

    it "creates NOT NULL columns, indexes, and triggers on a clean database" do
      issued = stub_embedding_schema(nullable: true, indexed: false, trigger_bodies: {})

      result = described_class.add_indexes!

      expect(result[:success]).to be true
      expect(result[:converged]).to be true
      expect(result[:message]).to include("ANN search enabled")
      expect(issued.grep(/ALTER TABLE memory_entities MODIFY/i)).not_to be_empty
      expect(issued.grep(/ALTER TABLE memory_observations MODIFY/i)).not_to be_empty
      expect(issued.grep(/ADD VECTOR INDEX idx_memory_entities_embedding/)).not_to be_empty
      expect(issued.grep(/ADD VECTOR INDEX idx_memory_observations_embedding/)).not_to be_empty
      expect(issued.grep(/CREATE TRIGGER trg_memory_entities_embedding_bi/)).not_to be_empty
      expect(issued.grep(/CREATE TRIGGER trg_memory_observations_embedding_bi/)).not_to be_empty
    end

    it "reinstalls dropped triggers on an otherwise converged database" do
      issued = stub_embedding_schema(
        nullable: false, indexed: true, trigger_bodies: {}
      )

      result = described_class.add_indexes!

      expect(result[:converged]).to be true
      expect(issued.grep(/ALTER TABLE/)).to be_empty
      expect(issued.grep(/CREATE TRIGGER trg_memory_entities_embedding_bi/)).not_to be_empty
      expect(issued.grep(/CREATE TRIGGER trg_memory_observations_embedding_bi/)).not_to be_empty
      expect(result[:performed].join).to include("triggers (re)installed")
    end

    it "changes nothing on a second consecutive run" do
      issued = stub_embedding_schema(nullable: true, indexed: false, trigger_bodies: {})

      described_class.add_indexes!
      issued.clear
      result = described_class.add_indexes!

      expect(result[:converged]).to be true
      expect(result[:performed]).to be_empty
      expect(issued.grep(/ALTER TABLE|CREATE TRIGGER|DROP TRIGGER/)).to be_empty
    end

    it "warns instead of altering an indexed column with a drifted default" do
      issued = stub_embedding_schema(
        nullable: false, indexed: true, trigger_bodies: correct_trigger_bodies,
        default_function: "'some other default'"
      )

      result = described_class.add_indexes!

      expect(result[:converged]).to be false
      expect(result[:warnings].join).to match(/unexpected default.*indexed column/i)
      expect(issued.grep(/ALTER TABLE/)).to be_empty
    end

    it "warns instead of altering an indexed column when dims drifted" do
      issued = stub_embedding_schema(
        nullable: false, indexed: true, trigger_bodies: correct_trigger_bodies,
        sql_type: "vector(8)", default_function: "VEC_FromText(concat('[',repeat('0,',7),'0]'))"
      )

      result = described_class.add_indexes!

      expect(result[:converged]).to be false
      expect(result[:warnings].join).to match(/vector\(8\).*vector\(4\)/i)
      expect(issued.grep(/ALTER TABLE/)).to be_empty
    end

    it "converges a drifted NOT NULL column when no index protects it" do
      issued = stub_embedding_schema(
        nullable: false, indexed: false, trigger_bodies: correct_trigger_bodies,
        default_function: nil
      )

      result = described_class.add_indexes!

      expect(result[:converged]).to be true
      expect(issued.grep(/ALTER TABLE \w+ MODIFY/i).size).to eq(2)
      expect(issued.grep(/ADD VECTOR INDEX/).size).to eq(2)
    end

    it "warns instead of altering an unindexed column whose dims drifted while rows exist" do
      issued = stub_embedding_schema(
        nullable: false, indexed: false, trigger_bodies: correct_trigger_bodies,
        sql_type: "vector(8)", default_function: "VEC_FromText(concat('[',repeat('0,',7),'0]'))"
      )

      result = described_class.add_indexes!

      expect(result[:converged]).to be false
      expect(result[:warnings].join).to match(/embeddings:regenerate/)
      expect(issued.grep(/MODIFY/)).to be_empty
    end

    it "installs each table's trigger before converging the next table" do
      order = []
      stub_embedding_schema(nullable: true, indexed: false, trigger_bodies: {})
      allow(EmbeddingVectorTriggerManager).to receive(:install!).and_wrap_original do |orig, **kw|
        order << kw[:only]
        orig.call(**kw)
      end

      described_class.add_indexes!

      expect(order).to eq([ %w[memory_entities], %w[memory_observations] ])
    end

    it "keeps the first table's triggers when the second table's ALTER fails" do
      issued = stub_embedding_schema(
        nullable: true, indexed: false, trigger_bodies: {},
        fail_on: /ALTER TABLE memory_observations MODIFY/
      )

      expect { described_class.add_indexes! }.to raise_error(EmbeddingIndexManager::Error, /boom/)
      expect(issued.grep(/CREATE TRIGGER trg_memory_entities_embedding_bi/)).not_to be_empty
    end

    it "warns instead of adding a second index under the canonical name" do
      issued = stub_embedding_schema(
        nullable: false, indexed: "custom_embedding_idx", trigger_bodies: correct_trigger_bodies
      )

      result = described_class.add_indexes!

      expect(result[:converged]).to be false
      expect(result[:warnings].join).to match(/already indexed as custom_embedding_idx/)
      expect(issued.grep(/ADD VECTOR INDEX/)).to be_empty
    end
  end

  describe ".drop_indexes!" do
    it "drops indexes and resets caches" do
      allow(conn).to receive(:execute).and_return([])
      expect(EmbeddingVectorTriggerManager).to receive(:drop!)
      expect(EmbeddingService).to receive(:reset_vector_cache!)
      expect(EmbeddingService).to receive(:reset_instance!)

      result = described_class.drop_indexes!

      expect(result[:success]).to be true
    end
  end

  # Runs against the real graph_mem_test DB. Skipped unless the schema is
  # already canonical — a converged run issues no DDL, so nothing implicitly
  # commits inside the transactional fixture.
  describe ".add_indexes! on the real test database", :real_db do
    it "succeeds as a no-op without issuing any DDL" do
      ddl = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_n, _s, _f, _id, payload|
        sql = payload[:sql].to_s
        ddl << sql if sql.match?(/\A\s*(ALTER|CREATE|DROP|TRUNCATE)/i)
      end

      result = described_class.add_indexes!

      expect(result[:success]).to be true
      expect(result[:converged]).to be true
      expect(ddl).to be_empty
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    it "recognizes the real stored column default as a zero vector" do
      real_conn = ActiveRecord::Base.connection
      column = real_conn.columns("memory_entities").find { |c| c.name == "embedding" }
      dims = EmbeddingConfig.resolved_config[:dims]

      expect(described_class.new.send(:zero_vector_default?, column, dims)).to be(true)
    end

    def canonical_embedding_schema?
      real_conn = ActiveRecord::Base.connection
      dims = EmbeddingConfig.resolved_config[:dims]
      EmbeddingIndexStatus::INDEX_NAMES.all? do |table, index_name|
        column = real_conn.columns(table.to_s).find { |c| c.name == "embedding" }
        column&.null == false &&
          column&.sql_type.to_s.include?("vector(#{dims})") &&
          real_conn.execute(
            "SHOW INDEX FROM #{table} WHERE Key_name = #{real_conn.quote(index_name)}"
          ).to_a.any?
      end &&
        EmbeddingVectorTriggerManager::TABLE_TRIGGERS.values.all? do |trigger|
          real_conn.execute(
            "SELECT 1 FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA = DATABASE() " \
            "AND TRIGGER_NAME = #{real_conn.quote(trigger)}"
          ).to_a.any?
        end &&
        MemoryEntity.missing_embedding.none? &&
        MemoryObservation.missing_embedding.none?
    rescue StandardError
      false
    end

    before do
      skip "test DB lacks the canonical embedding schema" unless canonical_embedding_schema?
    end
  end

  # Simulates the DB surface add_indexes! reads: column metadata, the
  # SHOW INDEX rows on the embedding column, and information_schema trigger
  # bodies. Issued DDL is recorded AND mutates the fake state, so a second
  # call sees the converged picture.
  #
  # Returns the array of issued SQL statements.
  def stub_embedding_schema(nullable:, indexed:, trigger_bodies:, sql_type: "vector(#{dims})", default_function: :auto, fail_on: nil)
    default_function = (nullable ? nil : zero_vec_function) if default_function == :auto
    state = %w[memory_entities memory_observations].to_h do |table|
      index_names =
        if indexed == true then [ "idx_#{table}_embedding" ]
        elsif indexed then Array(indexed)
        else []
        end
      [ table, {
        nullable: nullable,
        sql_type: sql_type,
        default_function: default_function,
        indexes: index_names
      } ]
    end
    triggers = trigger_bodies.dup
    issued = []

    allow(conn).to receive(:table_exists?).and_return(true)
    allow(conn).to receive(:column_exists?) do |table, column|
      state.key?(table.to_s) && column.to_s == "embedding"
    end
    allow(conn).to receive(:columns) do |table|
      st = state.fetch(table.to_s)
      [
        instance_double(
          ActiveRecord::ConnectionAdapters::Column,
          name: "embedding", null: st[:nullable],
          sql_type: st[:sql_type],
          default: nil, default_function: st[:default_function]
        )
      ]
    end
    allow(conn).to receive(:quote) { |value| "'#{value}'" }
    allow(conn).to receive(:execute) do |sql|
      raise ActiveRecord::StatementInvalid, "boom" if fail_on&.match?(sql)

      issued << sql
      apply_fake_ddl(sql, state, triggers)
    end
    # Reads: SHOW INDEX rows as hashes, trigger definitions, row presence.
    allow(conn).to receive(:select_all) do |sql|
      apply_fake_ddl(sql, state, triggers).map do |row|
        { "Key_name" => row[2], "Column_name" => row[4], "Index_type" => row[10] }
      end
    end
    allow(conn).to receive(:select_one) do |sql|
      name = sql[/TRIGGER_NAME = '?(\w+)'?/, 1]
      body = triggers[name]
      next unless body

      {
        "ACTION_STATEMENT" => body, "EVENT_MANIPULATION" => "INSERT",
        "ACTION_TIMING" => "BEFORE",
        "EVENT_OBJECT_TABLE" => EmbeddingVectorTriggerManager::TABLE_TRIGGERS.invert.fetch(name)
      }
    end
    allow(conn).to receive(:select_value).and_return(1)
    issued
  end

  def correct_trigger_bodies
    EmbeddingVectorTriggerManager::TABLE_TRIGGERS.values.index_with do
      "SET NEW.embedding = IFNULL(NEW.embedding, " \
        "VEC_FromText(CONCAT('[', REPEAT('0,', #{dims - 1}), '0]')))"
    end
  end

  # Responds to read queries from fake state and mutates it on DDL, mirroring
  # what a real MariaDB would do.
  def apply_fake_ddl(sql, state, triggers)
    case sql
    when /\ASHOW INDEX FROM (\w+)/i
      table = Regexp.last_match(1)
      matching = state.fetch(table)[:indexes].select do |name|
        sql.include?("Key_name = '#{name}'") || sql.include?("Column_name = 'embedding'")
      end
      matching.map do |name|
        [ table, 1, name, 1, "embedding", "A", nil, nil, nil, "", "VECTOR", "", "", "NO" ]
      end
    when /\AALTER TABLE (\w+) MODIFY/i
      st = state.fetch(Regexp.last_match(1))
      st[:nullable] = false
      st[:sql_type] = "vector(#{dims})"
      st[:default_function] = zero_vec_function
      nil
    when /\AALTER TABLE (\w+)\s+ADD VECTOR INDEX (\w+)/i
      state.fetch(Regexp.last_match(1))[:indexes] << Regexp.last_match(2)
      nil
    when /\ACREATE TRIGGER (\w+)/i
      triggers[Regexp.last_match(1)] = correct_trigger_bodies[Regexp.last_match(1)]
      nil
    when /\ADROP TRIGGER IF EXISTS (\w+)/i
      triggers[Regexp.last_match(1)] = nil
      nil
    end
  end
end
