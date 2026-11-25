# frozen_string_literal: true

require "rails_helper"

RSpec.describe SqlExport::Template do
  subject(:template) { described_class.new }

  let(:text) { template.before_data + template.after_data }

  it "supports the current schema: a migration adds a format version, or moves max_schema" do
    latest = Rails.root.glob("db/migrate/*.rb").map { |path| path.basename.to_s[/\A\d+/] }.max

    expect(described_class::MAX_SCHEMA.fetch(described_class::CURRENT_VERSION)).to be >= latest,
      "db/migrate is at #{latest}: if the migration touches memory_entities, memory_observations or memory_relations, " \
      "add lib/graph_mem/sql_exchange/v#{described_class::CURRENT_VERSION + 1}; otherwise move MAX_SCHEMA[#{described_class::CURRENT_VERSION}]"
  end

  it "takes the lock ProjectMembership takes, before the transaction" do
    lock = template.statements(:before_data).find { |statement| statement.start_with?("SET @gm_lock = GET_LOCK(") }
    expression = lock[/GET_LOCK\((CONCAT\(.*\)), 60\)\z/, 1]

    expect(ActiveRecord::Base.connection.select_value("SELECT #{expression}")).to eq(ProjectMembership.lock_name)
    expect(template.statements(:before_data).index(lock)).to be < template.statements(:before_data).index("START TRANSACTION")
    expect(template.statements(:before_data).count { |statement| template.client_only?(statement) }).to eq(2)
    expect(template.statements(:merge).last).to eq("COMMIT")
  end

  it "renders every placeholder and uses only temporary DDL, every gm_ table dropped first" do
    expect(text).not_to include("{{")
    statements = template.statements(:before_data) + template.statements(:guards) + template.statements(:merge)
    ddl = statements.grep(/\A(CREATE|ALTER|DROP|RENAME|TRUNCATE|GRANT)\b/i)
    expect(ddl).to all(match(/\A(CREATE|DROP) TEMPORARY TABLE /))
    expect(text).not_to match(/PROCEDURE|FUNCTION|TRIGGER|PREPARE|EXECUTE|LOAD_FILE|INTO OUTFILE|\bSLEEP\b/i)
    created = text.scan(/CREATE TEMPORARY TABLE (gm_\w+)/).flatten
    expect(template.drop_statement.scan(/gm_\w+/)).to match_array(created)
  end
end
