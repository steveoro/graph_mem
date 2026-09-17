# frozen_string_literal: true

class EntityCatalogService
  DEFAULT_PAGE = 1
  DEFAULT_PER_PAGE = 20
  MAX_PER_PAGE = 100

  def self.call(page: nil, per_page: nil)
    new(page: page, per_page: per_page).call
  end

  def initialize(page:, per_page:)
    @page = page.nil? ? DEFAULT_PAGE : page.to_i
    @per_page = per_page.nil? ? DEFAULT_PER_PAGE : per_page.to_i
  end

  def call
    validate_paging!

    total_entities = MemoryEntity.count
    entities = MemoryEntity.order(:id)
                           .limit(@per_page)
                           .offset((@page - 1) * @per_page)
                           .map { |entity| entity_payload(entity) }

    {
      entities: entities,
      pagination: {
        total_entities: total_entities,
        per_page: @per_page,
        current_page: @page,
        total_pages: [ (total_entities.to_f / @per_page).ceil, 1 ].max
      }
    }
  end

  private

  def validate_paging!
    if @page < 1
      raise FastMcp::Tool::InvalidArgumentsError,
            "page must be an integer >= 1; received #{@page}."
    end
    return if @per_page.between?(1, MAX_PER_PAGE)

    raise FastMcp::Tool::InvalidArgumentsError,
          "per_page must be an integer between 1 and #{MAX_PER_PAGE}; received #{@per_page}."
  end

  def entity_payload(entity)
    {
      entity_id: entity.id,
      name: entity.name,
      entity_type: entity.entity_type
    }
  end
end
