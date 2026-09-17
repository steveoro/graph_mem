# frozen_string_literal: true

class AddDashboardIndexesToToolInvocations < ActiveRecord::Migration[8.1]
  def change
    add_index :tool_invocations, %i[outcome created_at]
    add_index :tool_invocations, %i[error_category created_at]
  end
end
