# frozen_string_literal: true

# Entity ids from request parameters: positive integers only, at most 19 digits, so nothing but
# digits ever reaches a query. Shared by GET /api/v1/graph_data and the Explore page.
#
#   EntityIdList.parse("3, 1,3")  # => [3, 1]
#   EntityIdList.parse("1,,2")    # => nil
#   EntityIdList.id("42")         # => 42
module EntityIdList
  FORMAT = /\A[1-9]\d{0,18}\z/
  MAX = 100

  module_function

  # @param raw [Object] a comma-separated list
  # @param max [Integer]
  # @return [Array<Integer>, nil] de-duplicated ids, or nil unless 1 to max valid ids
  def parse(raw, max: MAX)
    return nil unless raw.is_a?(String)

    parts = raw.split(",", -1).map(&:strip)
    return nil unless parts.all? { |part| part.match?(FORMAT) }

    ids = parts.map(&:to_i).uniq
    ids if ids.size.between?(1, max)
  end

  # @param raw [Object]
  # @return [Integer, nil]
  def id(raw)
    raw.to_i if raw.is_a?(String) && raw.match?(FORMAT)
  end
end
