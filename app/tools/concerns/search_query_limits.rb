# frozen_string_literal: true

module SearchQueryLimits
  MAX_QUERY_LENGTH = 2_048

  def self.check!(query)
    return if query.nil?
    raise FastMcp::Tool::InvalidArgumentsError, "Query is too long (max 2048 characters)." \
      if query.to_s.length > MAX_QUERY_LENGTH
  end
end
