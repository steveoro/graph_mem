# frozen_string_literal: true

class MemoryEntity < ApplicationRecord
  include Auditable

  belongs_to :project, class_name: "MemoryEntity", optional: true
  # Members scoped to this Project root. RESTRICT (both the association and
  # the DB FK) means a project with members cannot be destroyed — the delete
  # paths surface that as an explicit refusal with the member count.
  has_many :members, class_name: "MemoryEntity", foreign_key: "project_id",
           dependent: :restrict_with_error, inverse_of: :project

  has_many :memory_observations, dependent: :destroy
  has_many :active_memory_observations,
           -> { active },
           class_name: "MemoryObservation",
           inverse_of: :memory_entity
  has_many :relations_from, class_name: "MemoryRelation", foreign_key: "from_entity_id", dependent: :destroy, inverse_of: :from_entity
  has_many :relations_to, class_name: "MemoryRelation", foreign_key: "to_entity_id", dependent: :destroy, inverse_of: :to_entity

  # Names are unique per project scope: project_id NULL (Project roots,
  # unclaimed reference stubs, operator-created globals) shares one global
  # namespace; project members repeat names freely across projects.
  validates :name, presence: true, uniqueness: { scope: :project_id, case_sensitive: false }
  validates :entity_type, presence: true
  # project_id may only point at a Project-typed entity — anything else would
  # detach the uniqueness scope from the part_of tree it mirrors.
  validate :project_is_project_type, if: -> { project_id.present? }

  after_initialize :set_default_counter_cache
  before_validation :canonicalize_entity_type
  after_create :set_initial_embedding
  after_commit :refresh_embedding, on: [ :update ], if: :embedding_fields_changed?
  before_update :invalidate_stale_embedding,
                if: -> { (changes_to_save.keys & EMBEDDING_FIELDS).any? }

  EMBEDDING_FIELDS = %w[name entity_type aliases description].freeze

  # `with_embedding`/`missing_embedding` track the `embedded_at` stamp
  # EmbeddingService#store_vector sets when a real vector is written —
  # NOT the vector itself (the BEFORE INSERT trigger fills placeholder
  # zero-vectors on this NOT NULL column).
  scope :with_embedding, -> { where.not(embedded_at: nil) }
  scope :missing_embedding, -> { where(embedded_at: nil) }

  def as_json(options = {})
    super(options.merge(except: Array(options[:except]) | [ :embedding ]))
  end

  private

  def project_is_project_type
    return if project&.entity_type == NodeOperationsStrategy::PROJECT_ENTITY_TYPE

    errors.add(:project_id, "must reference a Project entity")
  end

  def set_default_counter_cache
    self.memory_observations_count ||= 0
  end

  def canonicalize_entity_type
    return if entity_type.blank?

    canonical = EntityTypeMapping.canonicalize(entity_type)
    self.entity_type = canonical if canonical.present?
  end

  def set_initial_embedding
    return if EmbeddingService.inline_embeddings_suppressed?

    EmbeddingService.embed_entity(self)
  rescue StandardError => e
    Rails.logger.warn "MemoryEntity#set_initial_embedding failed: #{e.message}"
  end

  def embedding_fields_changed?
    (previous_changes.keys & EMBEDDING_FIELDS).any?
  end

  # Any write to embedded text invalidates the stored vector. Clear the stamp
  # inside the same UPDATE — even when the in-memory copy is already nil — so a
  # stamp written between our load and this save cannot survive it. Only
  # EmbeddingService#store_vector sets embedded_at (via compare-and-set).
  def invalidate_stale_embedding
    self.embedded_at = nil
    attribute_will_change!("embedded_at")
  end

  def refresh_embedding
    # Suppressed (bulk imports): the stamp was already cleared by
    # invalidate_stale_embedding — the deferred backfill re-embeds this row.
    return if EmbeddingService.inline_embeddings_suppressed?

    EmbeddingService.embed_entity(self)
  rescue StandardError => e
    Rails.logger.warn "MemoryEntity#refresh_embedding failed for id=#{id}: #{e.message}"
  end
end
