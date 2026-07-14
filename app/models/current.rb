# frozen_string_literal: true

class Current < ActiveSupport::CurrentAttributes
  attribute :actor
  attribute :deletion_reason
end
