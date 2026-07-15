# frozen_string_literal: true

module GraphTraversalToolSchema
  module_function

  def entity
    {
      type: :object,
      properties: {
        entity_id: { type: :integer },
        name: { type: :string },
        entity_type: { type: :string },
        aliases: { type: [ :string, :null ] },
        observations: {
          type: :array,
          items: observation
        },
        created_at: { type: :string, format: "date-time" },
        updated_at: { type: :string, format: "date-time" }
      },
      required: [ :entity_id, :name, :entity_type, :observations, :created_at, :updated_at ]
    }
  end

  def observation
    {
      type: :object,
      properties: {
        observation_id: { type: :integer },
        content: { type: :string },
        confidence: { type: [ :number, :null ] },
        source: { type: [ :string, :null ] },
        valid_from: { type: [ :string, :null ], format: "date-time" },
        valid_until: { type: [ :string, :null ], format: "date-time" },
        tags: { type: :array, items: { type: :string } },
        status: { type: :string, enum: MemoryObservation::STATUSES },
        obsoleted_at: { type: [ :string, :null ], format: "date-time" },
        obsolescence_reason: { type: [ :string, :null ] },
        superseded_by_id: { type: [ :integer, :null ] },
        created_at: { type: :string, format: "date-time" },
        updated_at: { type: :string, format: "date-time" }
      },
      required: [ :observation_id, :content, :status, :created_at, :updated_at ]
    }
  end

  def relation
    {
      type: :object,
      properties: {
        relation_id: { type: :integer },
        from_entity_id: { type: :integer },
        to_entity_id: { type: :integer },
        relation_type: { type: :string },
        weight: { type: [ :number, :null ] },
        confidence: { type: [ :number, :null ] },
        properties: { type: :object },
        created_at: { type: :string, format: "date-time" },
        updated_at: { type: :string, format: "date-time" }
      },
      required: [
        :relation_id, :from_entity_id, :to_entity_id, :relation_type,
        :created_at, :updated_at
      ]
    }
  end
end
