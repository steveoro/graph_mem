# frozen_string_literal: true

# The dependency-like entity types (Dream State R1b): the types of an entity a project uses rather
# than owns, such as a framework, a gem or a tool. The list is the `dependency_like_types` setting
# (Settings › Review policies), comma-separated. A type matches by its canonical type
# (EntityTypeMapping, the vocabulary's aliases included), compared case-insensitively with the
# listed types canonicalized the same way, so the default "Framework, Gem, Tool, SoftwareLibrary, TestFramework" also matches
# `library`, `lib`, `rubygem` and `tools`. A Project never matches.
#
# Read the setting once per unit of work and keep the matcher (the read is uncached):
#
#   types = DependencyLikeTypes.current
#   types.match?("rubygem")        # => true (Gem)
#   types.match?("Service")        # => false
#   types.entity?(entity)          # => true for a non-Project entity of a listed type
#   types.stored_types             # => ["Framework", "Gem", "library"] (the stored spellings that match)
#
# Used by the dream-state step that queues `swap` rows, phase 1's `add` rows, the
# auto_apply_relation_retype policy and the project scans.
class DependencyLikeTypes
  # Most entries the setting may hold, and the longest entry.
  MAX_ENTRIES = 20
  MAX_LENGTH = 64
  ENTRY_PATTERN = /\A[\p{L}\p{N}_](?:[\p{L}\p{N}_ .-]*[\p{L}\p{N}_])?\z/

  # @return [DependencyLikeTypes] the setting's list, read now
  def self.current
    new(AppSettings.dependency_like_types_list)
  end

  # @param raw [String, nil] a comma- or newline-separated list
  # @return [Array<String>] the stripped entries, without blanks or case-insensitive repeats
  def self.split(raw)
    raw.to_s.split(/[,\n]/).map(&:strip).reject(&:empty?).uniq(&:downcase)
  end

  # @param type [String, nil] an entity type, as stored or as written
  # @return [String] its canonical type (EntityTypeMapping), lower-cased; "" when blank
  def self.key(type)
    stripped = type.to_s.strip
    return "" if stripped.empty?

    (EntityTypeMapping.canonicalize(stripped) || stripped).downcase
  end

  # Checks a posted value of the setting (SettingsSchema::Validators.dependency_like_types).
  # @param raw [String, nil]
  # @return [Array(Array<String>, String)] the refused entries (empty when all are fine) and the
  #   normalized list to store ("A, B")
  def self.check(raw)
    entries = split(raw)
    project = key(NodeOperationsStrategy::PROJECT_ENTITY_TYPE)
    refused = entries.reject { |entry| entry.length <= MAX_LENGTH && entry.match?(ENTRY_PATTERN) && key(entry) != project }
    refused << "more than #{MAX_ENTRIES} types" if entries.size > MAX_ENTRIES
    [ refused, entries.join(", ") ]
  end

  # @param raw [String, nil] the list (see .split)
  def initialize(raw)
    @types = self.class.split(raw)
    project = self.class.key(NodeOperationsStrategy::PROJECT_ENTITY_TYPE)
    @keys = @types.map { |type| self.class.key(type) }.reject { |found| found == project }.to_set
  end

  # @return [Array<String>] the listed types, as written
  attr_reader :types

  # @return [Boolean] true when the list is blank (the R1b steps then do nothing)
  def empty? = @keys.empty?

  # @param entity_type [String, nil]
  # @return [Boolean] true when the type's canonical type is listed
  def match?(entity_type)
    found = self.class.key(entity_type)
    !found.empty? && @keys.include?(found)
  end

  # @param entity [MemoryEntity, nil]
  # @return [Boolean] true for a non-Project entity of a listed type
  def entity?(entity)
    !entity.nil? && entity.entity_type != NodeOperationsStrategy::PROJECT_ENTITY_TYPE && match?(entity.entity_type)
  end

  # The stored entity_type spellings that match, for queries (`where(entity_type: types.stored_types)`).
  # Memoized: one read of the distinct types.
  # @return [Array<String>]
  def stored_types
    @stored_types ||= empty? ? [] : MemoryEntity.distinct.pluck(:entity_type).select { |type| match?(type) }
  end
end
