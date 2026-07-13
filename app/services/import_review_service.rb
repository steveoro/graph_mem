# frozen_string_literal: true

# Loads and paginates temporary import review data for the operator UI.
class ImportReviewService
  PER_PAGE = 50

  class << self
    def items(matches, page: 1)
      matches ||= []
      Kaminari.paginate_array(matches).page(page).per(PER_PAGE)
    end
  end
end
