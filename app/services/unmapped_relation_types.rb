# frozen_string_literal: true

# The stored relation types that are neither canonical nor mapped (R1a, plan item 4):
# MemoryRelation.mapped_relation_type answers nil for them, so a sweep leaves them as they are
# (folded) and only the operator can map or accept them (System › Background jobs › Unmapped
# relation types).
#
# One row per folded type (MemoryRelation.fold_relation_type, the spelling a sweep stores), with
# the total use count of every stored spelling that folds to it: "Synth Link Kind", "synth link
# kind" and "synth-link-kind" are one row, `synth_link_kind`, listing those spellings. The counts
# come from one grouped query over the stored spellings (byte-wise, as the column's collation is
# case-insensitive), the examples from one windowed query, and the names from one more.
#
#   UnmappedRelationTypes.call(query: "synth")
#   # => [#<data Row type="synth_links_to", count=3, spellings={"synth_links_to"=>3},
#   #      examples=[#<data Example relation_id=41, from_id=7, from_name="SynthService", ...>]>]
class UnmappedRelationTypes
  EXAMPLES_PER_TYPE = 2

  # @!attribute type [String] the folded type
  # @!attribute count [Integer] relations stored with any of its spellings
  # @!attribute spellings [Hash{String => Integer}] stored spelling => its count
  # @!attribute examples [Array<Example>] up to EXAMPLES_PER_TYPE edges, oldest first
  Row = Data.define(:type, :count, :spellings, :examples)
  Example = Data.define(:relation_id, :from_id, :from_name, :to_id, :to_name, :relation_type)

  # @param query [String, nil] keeps the types whose folded type or a spelling contains it (any case)
  # @return [Array<Row>] sorted by count, descending, then by type
  def self.call(query: nil)
    groups = unmapped_spellings.group_by { |spelling, _count| MemoryRelation.fold_relation_type(spelling) }
    needle = query.to_s.strip.downcase
    groups.select! { |type, rows| type.include?(needle) || rows.any? { |spelling, _| spelling.downcase.include?(needle) } } if needle.present?
    examples = examples_for(groups.values.flatten(1).map(&:first))
    groups.map { |type, rows| Row.new(type: type, count: rows.sum(&:last), spellings: rows.to_h, examples: examples.fetch(type, [])) }
          .sort_by { |row| [ -row.count, row.type ] }
  end

  # Cache key of #cached_count.
  COUNT_CACHE_KEY = "relation_types/unmapped_count"
  COUNT_CACHE_TTL = 1.minute

  # The card's count, cached for COUNT_CACHE_TTL: the Background jobs cards are polled every few
  # seconds while a job runs, and #count reads the whole relations table. A mapping decision and a
  # finished sweep expire it (#expire_cached_count!); the unmapped-types page reads #call, exact.
  # @return [Integer]
  def self.cached_count
    Rails.cache.fetch(COUNT_CACHE_KEY, expires_in: COUNT_CACHE_TTL) { count }
  end

  # @return [void]
  def self.expire_cached_count!
    Rails.cache.delete(COUNT_CACHE_KEY)
  end

  # @return [Integer] how many folded types are unmapped, read now
  def self.count
    unmapped_spellings.map { |spelling, _count| MemoryRelation.fold_relation_type(spelling) }.uniq.size
  end

  # @param type [String] a folded type
  # @return [Integer] relations stored with a spelling that folds to it
  def self.relations_for(type)
    stored_spellings.sum { |spelling, count| MemoryRelation.fold_relation_type(spelling) == type ? count : 0 }
  end

  # @return [Array<Array(String, Integer)>] every stored spelling (byte-wise) with its count
  def self.stored_spellings
    MemoryRelation.where.not(relation_type: [ nil, "" ])
                  .group(Arel.sql("CAST(relation_type AS BINARY)"))
                  .pluck(Arel.sql("MIN(relation_type)"), Arel.sql("COUNT(*)"))
  end

  # @return [Array<Array(String, Integer)>] the stored spellings no mapping answers for
  def self.unmapped_spellings
    stored_spellings.select { |spelling, _count| MemoryRelation.mapped_relation_type(spelling).nil? }
  end

  # @param spellings [Array<String>]
  # @return [Hash{String => Array<Example>}] folded type => its first edges (by id)
  def self.examples_for(spellings)
    return {} if spellings.empty?

    ranked = MemoryRelation.where(relation_type: spellings)
                           .select(:id, :from_entity_id, :to_entity_id, :relation_type,
                                   Arel.sql("ROW_NUMBER() OVER (PARTITION BY CAST(relation_type AS BINARY) ORDER BY id) AS position"))
    rows = MemoryRelation.from(ranked, :memory_relations).where("position <= ?", EXAMPLES_PER_TYPE).order(:id)
                         .pluck(:id, :from_entity_id, :to_entity_id, :relation_type)
    names = MemoryEntity.where(id: rows.flat_map { |row| row[1, 2] }).pluck(:id, :name).to_h
    rows.group_by { |row| MemoryRelation.fold_relation_type(row.last) }.transform_values do |edges|
      edges.first(EXAMPLES_PER_TYPE).map do |id, from_id, to_id, type|
        Example.new(relation_id: id, from_id: from_id, from_name: names[from_id], to_id: to_id, to_name: names[to_id], relation_type: type)
      end
    end
  end
  private_class_method :examples_for
end
