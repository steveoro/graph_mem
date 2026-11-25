# frozen_string_literal: true

require "rails_helper"

# The validator is what keeps an uploaded graph_mem-sql file from running SQL of its own: each example
# tries one way past it, edits the file as an attacker could (signing it again), and expects a refusal.
RSpec.describe SqlImport::Validator do
  let!(:project) { fs_project!("SynthPrj") }
  let!(:widget) { fs_member!(project, "SynthWidget", "Component", description: "plain") }
  let(:script) { sql_export(project) }
  let(:data_line) { script[/^\(\d+, 1, 'SynthWidget'.*$/] }

  def refuses(text, message)
    expect { described_class.validate(text) }.to raise_error(described_class::Invalid, message)
  end

  it "accepts the writer's output, strings an attacker would like included, and imports them byte for byte" do
    nasty = "it's a \\'); DROP TABLE memory_entities; -- \"quote\" /*! 50000 x */ # \n\r\t\x00\x1a end ''"
    widget.update_columns(description: nasty)
    text = sql_export(project)
    parsed = described_class.validate(text)
    expect(parsed).to have_attributes(version: 1, header: include("roots" => "SynthPrj (Project)", "app" => GraphMem::VERSION))
    expect(parsed.data_statements).to all(start_with("INSERT INTO gm_stage_"))
    sql_delete_tree!(project)

    SqlImport::Executor.call(parsed)

    expect(MemoryEntity.find_by!(name: "SynthWidget").description).to eq(nasty)
  end

  it "refuses an unknown format, a missing or wrong digest, and a header line with a control character or an executable comment" do
    refuses(script.sub("-- graph_mem-sql v1", "-- graph_mem-sql v9"), /v9 is not known/)
    refuses(script.sub(/^-- sha256: .*\n/, ""), /no sha256 line/)
    refuses(script.sub("'SynthWidget'", "'SynthWidgeT'"), /does not match its sha256/)
    refuses(resign(script.sub("-- roots: SynthPrj", "-- roots: Synth\x01Prj")), /no sha256 line/)
    refuses(resign(script.sub("-- roots: SynthPrj", "-- roots: /*!50000 SynthPrj */")), /executable comment/)
    refuses("SELECT 1;\n", /not a graph_mem-sql script/)
  end

  it "refuses an edited template, a changed sql_mode line and changed line endings; the pinned mode keeps backslash escapes" do
    refuses(resign(script.sub("WHERE s.root_sk = 0;", "WHERE s.root_sk >= 0;")), /fixed part of the script differs/)
    refuses(resign(script.sub("SET SESSION sql_mode = '", "SET SESSION sql_mode = 'NO_BACKSLASH_ESCAPES,")), /fixed part/)
    refuses(resign(script.gsub("\n", "\r\n")), /line endings were changed/)
    expect(SqlExport::Template::SQL_MODE.split(",")).to eq(%w[STRICT_TRANS_TABLES STRICT_ALL_TABLES ERROR_FOR_DIVISION_BY_ZERO
                                                            NO_ZERO_DATE NO_ZERO_IN_DATE NO_ENGINE_SUBSTITUTION])
    expect(script).to include("SET SESSION sql_mode = '#{SqlExport::Template::SQL_MODE}';\n")
  end

  it "refuses any statement but a staging INSERT of the template's columns" do
    insert = "INSERT INTO gm_stage_entities (sk, root_sk, name, entity_type, aliases, description, created_at, updated_at) VALUES\n"
    refuses(resign(script.sub(insert, insert.sub("gm_stage_entities", "gm_stage_evil"))), /expected an INSERT INTO a staging table/)
    refuses(resign(script.sub(insert, insert.sub("gm_stage_entities", "memory_entities"))), /expected an INSERT INTO a staging table/)
    refuses(resign(script.sub(insert, insert.sub("aliases, ", ""))), /the column list of gm_stage_entities/)
    refuses(resign(script.sub(insert, "DELETE FROM memory_entities;\n#{insert}")), /expected an INSERT/)
    refuses(resign(script.sub(insert, "#{insert.chomp} -- x\n")), /the column list/)
  end

  it "refuses a value that is not a literal, a wrong arity, and a second statement on the line" do
    refuses(resign(script.sub(data_line, data_line.sub("'plain'", "SLEEP(5)"))), /expected a literal/)
    refuses(resign(script.sub(data_line, data_line.sub("'plain'", "'pl' 'ain'"))), /expected ', '|expected '\)'/)
    refuses(resign(script.sub(data_line, data_line.sub("'plain'", "'plain', NULL"))), /'\)' after 8 values/)
    refuses(resign(script.sub(data_line, data_line.sub(/;\z/, "; DELETE FROM memory_entities;"))), /new line/)
    refuses(resign(script.sub(data_line, data_line.sub("'plain'", "0x41"))), /expected ', '|expected '\)'/)
  end

  it "reads quoted strings by connection.quote's backslash rules, so neither \\' nor '' closes one early" do
    refuses(resign(script.sub(data_line, data_line.sub("'plain'", "'pl''ain'"))), /expected ', '|expected '\)'/)
    refuses(resign(script.sub(data_line, data_line.sub("'plain'", "'plain\\x'"))), /expected a literal/)
    refuses(resign(script.sub(data_line, data_line.sub("'plain'", "'plain\nmore'"))), /expected a literal/)
    # A \' the scanner would end the string on, as NO_BACKSLASH_ESCAPES would: it doesn't, so the
    # injected statement stays inside a string that never closes.
    refuses(resign(script.sub(data_line, data_line.sub("'plain'", "'x\\'), (1); DELETE FROM memory_entities; -- '"))), /expected/)
  end

  it "refuses executable comments and comments of any kind in the data part" do
    [ "/*!50000 DELETE FROM memory_entities */", "/*M!100000 DELETE FROM memory_entities */", "-- note", "# note", "/* note */" ].each do |comment|
      refuses(resign(script.sub(data_line, "#{comment}\n#{data_line}")), /found a comment/)
      refuses(resign(script.sub(data_line, data_line.sub("'plain'", "'plain' #{comment}"))), /expected/)
    end
  end

  it "refuses a file over the size cap before reading it" do
    path = Rails.root.join("tmp", "sql_import_validator_#{SecureRandom.hex(4)}.sql")
    File.write(path, script)
    stub_const("#{described_class}::MAX_BYTES", script.bytesize - 1)
    allow(File).to receive(:binread).and_call_original

    expect { described_class.validate_file(path) }.to raise_error(described_class::Invalid, /over the 0 MB limit/)
    expect(File).not_to have_received(:binread)
  ensure
    FileUtils.rm_f(path) if path
  end
end
