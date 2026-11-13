# frozen_string_literal: true

require "rails_helper"

RSpec.describe ObservationEvidence do
  def entity(name)
    MemoryEntity.create!(name: name, entity_type: "Task")
  end

  def hold(entities, content)
    Array(entities).each { |holder| MemoryObservation.create!(memory_entity: holder, content: content) }
  end

  let(:distinctive_fact) { "The importer retries three times with exponential backoff." }

  describe ".distinctive_contents" do
    it "returns an empty set for no contents without querying" do
      expect(described_class.distinctive_contents([])).to be_empty
    end

    it "keeps a long fact held by exactly two entities" do
      hold([ entity("EvA"), entity("EvB") ], distinctive_fact)

      expect(described_class.distinctive_contents([ distinctive_fact ])).to include(distinctive_fact)
    end

    it "keeps a long fact held by three entities: a triplicate's shared fact (Graphy, #172)" do
      hold(%w[EvA EvB EvC].map { |name| entity(name) }, distinctive_fact)

      expect(described_class.distinctive_contents([ distinctive_fact ])).to include(distinctive_fact)
    end

    it "drops a long fact held by four entities" do
      hold(%w[EvA EvB EvC EvD].map { |name| entity(name) }, distinctive_fact)

      expect(described_class.distinctive_contents([ distinctive_fact ])).to be_empty
    end

    it "does not count obsolete holders" do
      holders = %w[EvA EvB EvC EvD].map { |name| entity(name) }
      hold(holders, distinctive_fact)
      MemoryObservation.where(memory_entity: holders.last).first.mark_obsolete!

      expect(described_class.distinctive_contents([ distinctive_fact ])).to include(distinctive_fact)
    end

    it "drops short content" do
      short = "Too short to be evidence"
      hold([ entity("EvA"), entity("EvB") ], short)

      expect(described_class.distinctive_contents([ short ])).to be_empty
    end

    it "keeps long prose with a label in front (Graphy, #172): short Key: value lines fail the length" do
      labelled = "Decision: always validate uploads server-side before storing them"
      hold([ entity("EvA"), entity("EvB") ], labelled)

      expect(described_class.distinctive_contents([ labelled ])).to include(labelled)
    end

    it "drops a boilerplate sentence held by many entities" do
      boilerplate = "Successfully refactored to use the new syntax."
      hold(5.times.map { |index| entity("Clique#{index}") }, boilerplate)

      expect(described_class.distinctive_contents([ boilerplate ])).to be_empty
    end

    it "answers a whole batch with one grouped count query" do
      other = "Another distinctive observation about the scheduler internals."
      hold([ entity("EvA"), entity("EvB") ], distinctive_fact)
      hold([ entity("EvC"), entity("EvD") ], other)

      queries = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        queries << payload[:sql] if payload[:sql].include?("memory_observations")
      end
      result = described_class.distinctive_contents([ distinctive_fact, other ])
      ActiveSupport::Notifications.unsubscribe(subscriber)

      expect(result).to contain_exactly(distinctive_fact, other)
      expect(queries.size).to eq(1)
    end
  end

  describe ".distinctive?" do
    it "is true for a rare long fact and false for a short metadata line" do
      hold([ entity("EvA"), entity("EvB") ], distinctive_fact)

      expect(described_class.distinctive?(distinctive_fact)).to be(true)
      expect(described_class.distinctive?("Status: Completed")).to be(false)
    end
  end
end
