# frozen_string_literal: true

require "rails_helper"
require_relative "../../lib/import_session"

# The temp files of an uploaded graph_mem-sql script between its preview and its execute.
RSpec.describe ImportSession do
  let(:script) { "-- graph_mem-sql v1\n-- synthetic\n" }
  let(:meta) { { file_name: "synth_prj.sql", producer: "graph_mem-sql" } }
  let(:session_ids) { [] }

  after { session_ids.each { |id| described_class.cleanup(id) } }

  def create_session
    described_class.create_sql(StringIO.new(script), meta: meta).tap { |id| session_ids << id }
  end

  describe ".create_sql" do
    it "stores the script as it is under a fresh UUID, with what the upload was" do
      session_id = create_session

      expect(session_id).to match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
      expect(File.binread(described_class.sql_path(session_id))).to eq(script)
      expect(described_class.load_meta(session_id)).to eq(meta)
      expect(create_session).not_to eq(session_id)
    end
  end

  describe ".exists? and .sql?" do
    it "is true for a stored script" do
      session_id = create_session

      expect([ described_class.exists?(session_id), described_class.sql?(session_id) ]).to eq([ true, true ])
    end

    it "is false for an unknown or blank id" do
      [ "non-existent-id", nil, "" ].each do |session_id|
        expect([ described_class.exists?(session_id), described_class.sql?(session_id) ]).to eq([ false, false ])
      end
    end

    it "is false for the files a JSON upload left before 1.94.0" do
      session_id = SecureRandom.uuid
      FileUtils.mkdir_p(described_class::TEMP_DIR)
      leftover = described_class::TEMP_DIR.join("#{session_id}_data.json")
      File.write(leftover, "{}")

      expect(described_class.exists?(session_id)).to be(false)
    ensure
      FileUtils.rm_f(leftover)
    end
  end

  describe ".store_preview and .load_preview" do
    it "stores the dry run's preview and loads it with string keys" do
      session_id = create_session

      expect(described_class.load_preview(session_id)).to be_nil
      described_class.store_preview(session_id, { summary: { memory_entities: { new: 2 } } })

      expect(described_class.load_preview(session_id)).to eq("summary" => { "memory_entities" => { "new" => 2 } })
    end
  end

  describe ".load_meta" do
    it "is empty for a session without a meta file" do
      expect(described_class.load_meta(SecureRandom.uuid)).to eq({})
    end
  end

  describe ".cleanup" do
    it "removes the script, its meta and its preview" do
      session_id = create_session
      described_class.store_preview(session_id, { summary: {} })

      described_class.cleanup(session_id)

      expect(described_class.exists?(session_id)).to be(false)
      expect(described_class::TEMP_DIR.glob("#{session_id}_*")).to be_empty
    end

    it "handles nil session_id gracefully" do
      expect { described_class.cleanup(nil) }.not_to raise_error
    end
  end
end
