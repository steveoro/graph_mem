# frozen_string_literal: true

# Zero-vector placeholders (step 0 of docs/plans/mariadb-vector-search-plan.md). With the VECTOR KEYs
# installed, the embedding columns are NOT NULL and a BEFORE INSERT trigger stores the zero vector
# in a row nobody has embedded yet: the row holds a vector while `embedded_at` stays NULL. MariaDB's
# cosine distance to the zero vector is NaN, which the client reads as 0.0
# (spec/db/zero_vector_distance_spec.rb), so only `embedded_at` tells a placeholder from a real vector.
#
# The committed schema (db/structure.sql, loaded by `db:schema:load` and `db:test:prepare`) already
# has the NOT NULL columns, the VECTOR KEYs and the triggers, so every spec runs on that install.
# Nothing is installed or dropped here, so a failing example can't leave DDL behind. The shared
# context checks the install once per group and fails the group when a piece is missing: without the
# placeholder these specs would pass without testing anything.
#
#   RSpec.describe ObservationRelevanceRanker, :with_test_embeddings do
#     include_context "zero-vector placeholders"
#
#     it "skips the placeholder" do
#       record_embedding_calls!
#       pending_fact = unembedded { MemoryObservation.create!(memory_entity: entity, content: "SynthFact") }
#       sql = vector_distance_sql { ranker.score_batch([ pending_fact ]) }
#     end
#   end
module ZeroVectorHelpers
  MIN_MARIADB = "11.8"

  module_function

  # The pieces of the index install that are missing on the test database.
  #
  # @return [Array<String>] one line per missing piece; empty when the install is complete
  def schema_problems
    connection = ActiveRecord::Base.connection
    EmbeddingIndexStatus::INDEX_NAMES.flat_map do |table, index_name|
      column = connection.columns(table.to_s).find { |col| col.name == "embedding" }
      trigger = EmbeddingVectorTriggerManager::TABLE_TRIGGERS.fetch(table.to_s)
      [
        ("#{table}.embedding is missing or nullable" unless column && !column.null),
        ("#{index_name} is missing" unless EmbeddingIndexStatus.index_exists?(table.to_s, index_name)),
        ("#{trigger} is missing" unless trigger_installed?(connection, trigger))
      ].compact
    end
  end

  # @param version [String] a MariaDB version such as "11.8"
  # @return [Boolean] true when the test database is MariaDB at +version+ or later
  def mariadb_at_least?(version = MIN_MARIADB)
    server = ActiveRecord::Base.connection.select_value("SELECT VERSION()").to_s
    return false unless server.match?(/mariadb/i)

    Gem::Version.new(server[/\A\d+(\.\d+)*/]) >= Gem::Version.new(version)
  end

  # @param record [MemoryEntity, MemoryObservation]
  # @return [Boolean] true when the row (read from the database, not the in-memory copy) holds the
  #   zero vector and has no `embedded_at` stamp
  def zero_vector_placeholder?(record)
    vector, embedded_at = record.class.where(id: record.id).pick(:embedding, :embedded_at)
    vector.present? && embedded_at.nil? && vector.to_s.unpack("e*").all?(&:zero?)
  end

  def trigger_installed?(connection, trigger)
    connection.select_value(
      "SELECT 1 FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA = DATABASE() " \
      "AND TRIGGER_NAME = #{connection.quote(trigger)}"
    ).present?
  end
  private_class_method :trigger_installed?

  # Example-level helpers, included by the shared context.
  module Example
    # Runs the block with inline embeddings suppressed, so the records it creates keep the zero-vector
    # placeholder, and checks each one does.
    #
    # @yieldreturn [ActiveRecord::Base, Array<ActiveRecord::Base>] the records created
    # @return [ActiveRecord::Base, Array<ActiveRecord::Base>] the same records, reloaded
    def unembedded(&block)
      created = EmbeddingService.suppress_inline_embeddings(&block)
      Array(created).each do |record|
        expect(ZeroVectorHelpers.zero_vector_placeholder?(record)).to be(true), "#{record.class.name} ##{record.id} holds no zero-vector placeholder"
      end
      created.is_a?(Array) ? created.map(&:reload) : created.reload
    end

    # @yield the code under test
    # @return [Array<String>] the SQL statements that computed a vector distance while the block ran
    def vector_distance_sql(&block)
      statements = []
      callback = lambda do |_name, _start, _finish, _id, payload|
        sql = payload[:sql].to_s
        statements << sql if sql.match?(/VEC_DISTANCE/i)
      end
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &block)
      statements
    end
  end
end

RSpec.shared_context "zero-vector placeholders" do
  include ZeroVectorHelpers::Example

  before(:all) do
    problems = ZeroVectorHelpers.schema_problems
    if problems.any?
      raise "The zero-vector specs need the index install of db/structure.sql " \
            "(run `bin/rails db:test:prepare`): #{problems.join('; ')}"
    end
  end
end
