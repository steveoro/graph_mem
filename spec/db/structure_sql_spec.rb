# frozen_string_literal: true

require "spec_helper"

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
