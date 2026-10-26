# frozen_string_literal: true

class Current < ActiveSupport::CurrentAttributes
  attribute :actor
  attribute :deletion_reason
  # The open ChangeSet::Context (UI-4a), set by ChangeSet.record.
  attribute :change_set
end
