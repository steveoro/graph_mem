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
end

RSpec.describe StructureDumpCleaner do
  let(:trigger_line) do
    "/*!50003 CREATE*/ /*!50003 TRIGGER trg_x BEFORE INSERT ON t FOR EACH ROW SET NEW.x = 1"
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
