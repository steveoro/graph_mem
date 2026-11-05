# frozen_string_literal: true

require "rails_helper"

# F-3b step S: db/structure.sql loads through the connection, statement by statement.
RSpec.describe GraphMem::ScanProfile::StructureLoader do
  let(:dump) do
    <<~SQL
      /*M!999999\\- enable the sandbox mode */#{' '}
      /*!40101 SET NAMES utf8mb4 */;
      CREATE TABLE `synth_widgets` (
        `id` bigint(20) NOT NULL AUTO_INCREMENT,
        PRIMARY KEY (`id`)
      ) ENGINE=InnoDB;
      DELIMITER ;;
      /*!50003 CREATE*/ /*!50017 DEFINER=`root`@`localhost`*/ /*!50003 TRIGGER trg_synth BEFORE INSERT ON synth_widgets FOR EACH ROW SET NEW.id = NEW.id */;;
      DELIMITER ;
      INSERT INTO `schema_migrations` (version) VALUES
      ('20260101000000'),
      ('20260101000001');
    SQL
  end

  it "splits on the current delimiter, skips the client-only line and drops the DEFINER" do
    statements = described_class.statements(dump)

    expect(statements.size).to eq(4)
    expect(statements.first).to eq("/*!40101 SET NAMES utf8mb4 */")
    expect(statements[1]).to start_with("CREATE TABLE `synth_widgets`").and end_with("ENGINE=InnoDB")
    expect(statements[2]).to eq("/*!50003 CREATE*/ /*!50003 TRIGGER trg_synth BEFORE INSERT ON synth_widgets FOR EACH ROW SET NEW.id = NEW.id */")
    expect(statements[3]).to include("('20260101000001')")
    expect(statements[3]).not_to end_with(";")
  end

  it "finds every table and trigger of db/structure.sql" do
    sql = Rails.root.join("db/structure.sql").read
    statements = described_class.statements(sql)

    expect(statements.count { |statement| statement.start_with?("CREATE TABLE") }).to eq(sql.scan(/^CREATE TABLE /).size)
    expect(statements.grep(/TRIGGER trg_/).size).to eq(sql.scan(/TRIGGER trg_/).size)
    expect(statements.grep(/DEFINER=/)).to be_empty
  end
end
