# frozen_string_literal: true

class AddLastToolNameToAgentContexts < ActiveRecord::Migration[8.0]
  def change
    add_column :agent_contexts, :last_tool_name, :string
  end
end
