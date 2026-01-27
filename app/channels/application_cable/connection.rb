# frozen_string_literal: true

module ApplicationCable
  class Connection < ActionCable::Connection::Base
    # For now, we don't require authentication for export progress
    # In a production app, you might want to identify the user here
  end
end
