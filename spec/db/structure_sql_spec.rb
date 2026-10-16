# frozen_string_literal: true

require "rails_helper"

# db/structure.sql must stay loadable on a fresh MariaDB instance. Query-log
# tags (/*application='GraphMem'*/) leak into dumped trigger bodies under
# development config and break db:schema:load with ERROR 1064 — the
# db:schema:dump enhancement in lib/tasks/structure_dump.rake strips them.
RSpec.describe "db/structure.sql" do
  let(:structure_sql) { Rails.root.join("db/structure.sql").read }

  it "contains no query-log marginalia inside trigger bodies" do
    expect(structure_sql).not_to match(%r{/\*application=})
  end

  it "writes trigger terminators on the dump's own one-line format" do
    expect(structure_sql.scan(%r{TRIGGER .*? \*/;;}m).size).to eq(2)
  end

  it "carries the full indexed embedding schema (NOT NULL + VECTOR KEY)" do
    expect(structure_sql.scan(/`embedding` vector\(\d+\) NOT NULL/i).size).to eq(2)
    expect(structure_sql.scan(/VECTOR KEY `idx_memory_\w+_embedding`/i).size).to eq(2)
  end
end

RSpec.describe StructureDumpCleaner do
  let(:trigger_line) do
    "/*!50003 CREATE*/ /*!50017 DEFINER=`root`@`localhost`*/ /*!50003 TRIGGER trg_x BEFORE INSERT ON t FOR EACH ROW SET NEW.x = 1"
  end

  it "strips marginalia on the same line as the terminator (real dev dump)" do
    dirty = "#{trigger_line} /*application='GraphMem'*/ */;;\n"
    expect(described_class.call(dirty)).to eq("#{trigger_line} */;;\n")
  end

  it "strips marginalia separated from the terminator by whitespace/newlines" do
    dirty = "#{trigger_line} /*application='GraphMem'*/ \n*/;;\n"
    expect(described_class.call(dirty)).to eq("#{trigger_line} */;;\n")
  end

  it "leaves clean trigger lines untouched" do
    clean = "#{trigger_line} */;;\n"
    expect(described_class.call(clean)).to eq(clean)
  end
end

RSpec.describe StructureDumpGuard do
  let(:canonical_dump) do
    <<~SQL
      CREATE TABLE `memory_entities` (
        `id` bigint(20) NOT NULL AUTO_INCREMENT,
        `embedding` vector(768) NOT NULL,
        VECTOR KEY `idx_memory_entities_embedding` (`embedding`) `DISTANCE`='cosine'
      );
      DELIMITER ;;
      /*!50003 CREATE*/ /*!50017 DEFINER=`root`@`localhost`*/ /*!50003 TRIGGER trg_memory_entities_embedding_bi BEFORE INSERT ON memory_entities FOR EACH ROW SET NEW.embedding = IFNULL(NEW.embedding, 'x') */;;
      DELIMITER ;
      CREATE TABLE `memory_observations` (
        `id` bigint(20) NOT NULL AUTO_INCREMENT,
        `embedding` vector(768) NOT NULL,
        VECTOR KEY `idx_memory_observations_embedding` (`embedding`) `DISTANCE`='cosine'
      );
      DELIMITER ;;
      /*!50003 CREATE*/ /*!50017 DEFINER=`root`@`localhost`*/ /*!50003 TRIGGER trg_memory_observations_embedding_bi BEFORE INSERT ON memory_observations FOR EACH ROW SET NEW.embedding = IFNULL(NEW.embedding, 'x') */;;
      DELIMITER ;
    SQL
  end

  # Same tables on a DB where `embeddings:add_indexes` never ran.
  let(:degraded_dump) do
    <<~SQL
      CREATE TABLE `memory_entities` (
        `id` bigint(20) NOT NULL AUTO_INCREMENT,
        `embedding` vector(768) DEFAULT NULL
      );
      CREATE TABLE `memory_observations` (
        `id` bigint(20) NOT NULL AUTO_INCREMENT,
        `embedding` vector(768) DEFAULT NULL
      );
    SQL
  end

  before { described_class.snapshot = nil }

  it "passes a canonical dump through untouched" do
    expect(described_class.call(canonical_dump)).to eq(canonical_dump)
  end

  it "restores the previous canonical dump when the fresh one lost the embedding indexes" do
    described_class.snapshot = canonical_dump
    expect { expect(described_class.call(degraded_dump)).to eq(canonical_dump) }
      .to output(/without the embedding indexes\/triggers/).to_stderr
  end

  it "keeps the fresh dump (with a warning) when no canonical snapshot exists" do
    expect { expect(described_class.call(degraded_dump)).to eq(degraded_dump) }
      .to output(/no previous canonical dump/).to_stderr
  end

  it "warns but keeps dumps that carry no embedding columns at all" do
    column_less = "CREATE TABLE `memory_entities` (\n  `id` bigint(20) NOT NULL\n);\n"
    expect { expect(described_class.call(column_less)).to eq(column_less) }
      .to output(/no embedding VECTOR columns/).to_stderr
  end

  it "bypasses the guard when GRAPH_MEM_ALLOW_UNINDEXED_DUMP is set" do
    described_class.snapshot = canonical_dump
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("GRAPH_MEM_ALLOW_UNINDEXED_DUMP").and_return("1")
    expect(described_class.call(degraded_dump)).to eq(degraded_dump)
  end

  def with_migration_versions(dump, versions)
    insert = "INSERT INTO `schema_migrations` (version) VALUES\n" +
             versions.map { |v| "('#{v}')" }.join(",\n") + ";\n"
    "#{dump}\n#{insert}"
  end

  it "raises instead of restoring when the degraded dump carries new migrations" do
    described_class.snapshot = with_migration_versions(canonical_dump, %w[20261001000000])
    # The probe Graphy ran: a new column AND a schema_migrations row the
    # snapshot predates — restoring the snapshot would erase both.
    fresh = with_migration_versions(degraded_dump, %w[20261001000000 20261105000000])
            .sub(");\n", "  `new_flag` tinyint(1) DEFAULT NULL\n);\n")

    expect { described_class.call(fresh) }
      .to raise_error(StructureDumpGuard::UnrecoverableDumpError, /20261105000000/)
  end

  it "still restores when the degraded dump carries the same migrations" do
    described_class.snapshot = with_migration_versions(canonical_dump, %w[20261001000000])
    fresh = with_migration_versions(degraded_dump, %w[20261001000000])

    expect { expect(described_class.call(fresh)).to eq(described_class.snapshot) }
      .to output(/without the embedding indexes\/triggers/).to_stderr
  end

  it "still restores when the fresh dump is missing versions the snapshot has" do
    # A stale DB dumped — restoring is strictly beneficial here.
    described_class.snapshot = with_migration_versions(canonical_dump, %w[20261001000000 20261105000000])
    fresh = with_migration_versions(degraded_dump, %w[20261001000000])

    expect { expect(described_class.call(fresh)).to eq(described_class.snapshot) }
      .to output(/Restored the previous/).to_stderr
  end

  describe ".process_file!" do
    let(:file) do
      Tempfile.new([ "structure", ".sql" ]).tap { |f| f.write(file_content) && f.flush }
    end
    let(:path) { Pathname.new(file.path) }

    after { file.close! }

    context "when the dump is unrecoverable" do
      let(:file_content) do
        with_migration_versions(degraded_dump, %w[20261001000000 20261105000000])
      end

      it "writes the snapshot back and aborts with a non-zero exit" do
        described_class.snapshot = with_migration_versions(canonical_dump, %w[20261001000000])

        expect { described_class.process_file!(path) }
          .to raise_error(SystemExit)
          .and output(/ERROR:.*20261105000000/).to_stderr
        expect(path.read).to eq(described_class.snapshot)
      end
    end

    context "when the fresh dump is canonical" do
      let(:file_content) { canonical_dump }

      it "writes the cleaned content without aborting" do
        expect { described_class.process_file!(path) }.not_to raise_error
        expect(path.read).to eq(canonical_dump)
      end
    end
  end
end

# Pin the enhance wiring itself — replacing the process_file! call with a
# no-op in the rake block must fail this spec (mutation M1d).
RSpec.describe "db:schema:dump guard wiring" do
  before { Rails.application.load_tasks }

  it "snapshots before the dump and runs the guard afterwards" do
    task = Rake::Task["db:schema:dump"]
    expect(task.prerequisites).to include("db:snapshot_structure_sql")

    guard_action = task.actions.find do |action|
      action.source_location&.first.to_s.end_with?("structure_dump.rake")
    end
    expect(guard_action).not_to be_nil

    allow(StructureDumpGuard).to receive(:process_file!)
    guard_action.call
    expect(StructureDumpGuard).to have_received(:process_file!)
      .with(Rails.root.join("db/structure.sql"))
  end
end

# The generated column backing the stale-memory candidate lock: without it
# the FOR UPDATE scans every stale row and X-locks them all.
RSpec.describe "maintenance_report_rows.stale_entity_id" do
  let(:report) { MaintenanceReport.create!(report_type: "stale_memory_scan", data: { "source" => "test" }) }

  def write_row(kind:, payload:, edited: nil)
    MaintenanceReportRow.create!(
      maintenance_report: report,
      report_type: "stale_memory_scan",
      row_uuid: SecureRandom.uuid,
      kind: kind,
      status: "active",
      signature: "sig-#{SecureRandom.hex(4)}",
      payload: payload,
      edited_payload: edited
    )
  end

  it "computes entity_id from the payload for stale_memory rows" do
    row = write_row(kind: "stale_memory", payload: { "entity_id" => 42 })
    expect(row.reload.stale_entity_id).to eq(42)
  end

  it "prefers an operator-edited entity_id (effective_payload semantics)" do
    row = write_row(kind: "stale_memory", payload: { "entity_id" => 42 }, edited: { "entity_id" => 7 })
    expect(row.reload.stale_entity_id).to eq(7)
  end

  it "is NULL for non-stale kinds even when the payload carries an id" do
    row = write_row(kind: "entity_merge", payload: { "entity_id" => 42 })
    expect(row.reload.stale_entity_id).to be_nil
  end

  it "is NULL (never an insert error) for non-numeric entity_ids" do
    row = write_row(kind: "stale_memory", payload: { "entity_id" => "abc" })
    expect(row.reload.stale_entity_id).to be_nil
  end
end
