# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmbeddingVectorTriggerManager do
  let(:conn) { instance_double(ActiveRecord::ConnectionAdapters::Mysql2Adapter) }
  let(:correct_body) do
    "SET NEW.embedding = IFNULL(NEW.embedding, " \
      "VEC_FromText(CONCAT('[', REPEAT('0,', 3), '0]'))) /*application='GraphMem'*/"
  end

  before do
    allow(ActiveRecord::Base).to receive(:connection).and_return(conn)
    allow(EmbeddingConfig).to receive(:resolved_config).and_return(
      url: "http://localhost:11434",
      model: "test",
      provider: "ollama",
      dims: 4
    )
    allow(conn).to receive(:table_exists?).and_return(true)
    allow(conn).to receive(:columns).and_return([
      instance_double(ActiveRecord::ConnectionAdapters::Column, name: "embedding", null: false)
    ])
    allow(conn).to receive(:quote) { |value| "'#{value}'" }
    allow(conn).to receive(:execute)
    allow(conn).to receive(:select_one).and_return(nil)
  end

  describe ".install!" do
    it "creates zero-vector insert triggers for embedding tables" do
      result = described_class.install!

      expect(conn).to have_received(:execute).with("DROP TRIGGER IF EXISTS trg_memory_entities_embedding_bi")
      expect(conn).to have_received(:execute).with("DROP TRIGGER IF EXISTS trg_memory_observations_embedding_bi")
      expect(conn).to have_received(:execute).with(
        a_string_matching(/CREATE TRIGGER trg_memory_entities_embedding_bi.*REPEAT\('0,', 3\)/)
      )
      expect(conn).to have_received(:execute).with(
        a_string_matching(/CREATE TRIGGER trg_memory_observations_embedding_bi.*REPEAT\('0,', 3\)/)
      )
      expect(result[:installed]).to contain_exactly(
        "trg_memory_entities_embedding_bi", "trg_memory_observations_embedding_bi"
      )
    end

    it "skips nullable embedding columns" do
      allow(conn).to receive(:columns).and_return([
        instance_double(ActiveRecord::ConnectionAdapters::Column, name: "embedding", null: true)
      ])

      result = described_class.install!

      expect(conn).not_to have_received(:execute)
      expect(result[:skipped].join).to match(/still nullable/)
    end

    it "skips missing tables" do
      allow(conn).to receive(:table_exists?).and_return(false)

      result = described_class.install!

      expect(conn).not_to have_received(:execute)
      expect(result[:skipped].join).to match(/missing/)
    end

    it "leaves already-correct triggers untouched" do
      stub_trigger_bodies(
        {
        "trg_memory_entities_embedding_bi" => correct_body,
        "trg_memory_observations_embedding_bi" => correct_body
        }
      )

      result = described_class.install!

      expect(conn).not_to have_received(:execute).with(a_string_matching(/DROP TRIGGER|CREATE TRIGGER/))
      expect(result[:unchanged]).to contain_exactly(
        "trg_memory_entities_embedding_bi", "trg_memory_observations_embedding_bi"
      )
      expect(result[:installed]).to be_empty
    end

    it "treats a body with backticked identifiers as correct" do
      backticked = correct_body.sub("NEW.embedding, ", "NEW.`embedding`, ")
      stub_trigger_bodies(
        {
        "trg_memory_entities_embedding_bi" => backticked,
        "trg_memory_observations_embedding_bi" => backticked
        }
      )

      result = described_class.install!

      expect(result[:installed]).to be_empty
      expect(result[:unchanged].size).to eq(2)
    end

    it "recreates triggers whose body drifted" do
      stub_trigger_bodies(
        {
        "trg_memory_entities_embedding_bi" => "SET NEW.embedding = NULL",
        "trg_memory_observations_embedding_bi" => correct_body
        }
      )

      result = described_class.install!

      expect(conn).to have_received(:execute).with("DROP TRIGGER IF EXISTS trg_memory_entities_embedding_bi")
      expect(conn).to have_received(:execute).with(
        a_string_matching(/CREATE TRIGGER trg_memory_entities_embedding_bi/)
      )
      expect(result[:installed]).to eq([ "trg_memory_entities_embedding_bi" ])
      expect(result[:unchanged]).to eq([ "trg_memory_observations_embedding_bi" ])
    end
  end

  describe ".install! (definition checks)" do
    let(:bodies) do
      { "trg_memory_entities_embedding_bi" => correct_body,
        "trg_memory_observations_embedding_bi" => correct_body }
    end

    it "recreates a trigger attached to the wrong event or timing" do
      stub_trigger_bodies(bodies, event: "UPDATE")

      result = described_class.install!

      expect(result[:installed].size).to eq(2)
    end

    it "recreates a trigger whose body is right but whose table is wrong" do
      stub_trigger_bodies(bodies, tables: Hash.new("memory_relations"))

      expect(described_class.install!(only: %w[memory_entities])[:installed]).to eq(
        [ "trg_memory_entities_embedding_bi" ]
      )
    end

    it "propagates query errors instead of recreating a healthy trigger" do
      allow(conn).to receive(:select_one).and_raise(ActiveRecord::StatementInvalid, "gone away")

      expect { described_class.install! }.to raise_error(ActiveRecord::StatementInvalid)
      expect(conn).not_to have_received(:execute).with(a_string_matching(/DROP TRIGGER|CREATE TRIGGER/))
    end

    it "limits work to the requested tables" do
      stub_trigger_bodies(bodies)

      result = described_class.install!(only: %w[memory_observations])

      expect(result[:unchanged]).to eq([ "trg_memory_observations_embedding_bi" ])
    end
  end

  describe ".drop!" do
    it "drops embedding insert triggers" do
      described_class.drop!

      expect(conn).to have_received(:execute).with("DROP TRIGGER IF EXISTS trg_memory_entities_embedding_bi")
      expect(conn).to have_received(:execute).with("DROP TRIGGER IF EXISTS trg_memory_observations_embedding_bi")
    end
  end

  # information_schema.TRIGGERS reads go through select_one; DDL through execute.
  def stub_trigger_bodies(bodies, event: "INSERT", timing: "BEFORE", tables: nil)
    allow(conn).to receive(:select_one) do |sql|
      name = sql[/TRIGGER_NAME = '?(\w+)'?/, 1]
      body = bodies[name]
      next unless body

      {
        "ACTION_STATEMENT" => body,
        "EVENT_MANIPULATION" => event,
        "ACTION_TIMING" => timing,
        "EVENT_OBJECT_TABLE" => (tables || described_class::TABLE_TRIGGERS.invert)[name]
      }
    end
  end
end
