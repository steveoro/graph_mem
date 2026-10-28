# frozen_string_literal: true

# Helpers for the Search page (UI-3).
#
#   highlight_snippet("SynthWidget <b>renders</b> tiles", %w[tiles]) # => "SynthWidget &lt;b&gt;renders&lt;/b&gt; <mark>tiles</mark>"
module SearchHelper
  SNIPPET_LENGTH = 240

  # The raw text, cut to ~SNIPPET_LENGTH characters around the first hit, with every token
  # match wrapped in <mark>. The text is split on the tokens BEFORE escaping and each piece is
  # escaped on its own, so a token never matches inside an entity (`amp` in `&amp;`) and the
  # only markup in the result is the <mark> tags. This is the page's only html_safe.
  #
  # @param text [String, nil] raw, unescaped observation or description text
  # @param tokens [Array<String>] search tokens (QueryTokenizer output)
  # @return [ActiveSupport::SafeBuffer]
  def highlight_snippet(text, tokens)
    text = snippet_window(text.to_s, tokens)
    tokens = Array(tokens).compact_blank.uniq
    return ERB::Util.html_escape(text) if tokens.empty?

    pattern = Regexp.union(tokens.sort_by { |token| -token.length }.map { |token| Regexp.new(Regexp.escape(token), Regexp::IGNORECASE) })
    text.split(/(#{pattern})/).each_with_index.map do |segment, index|
      escaped = ERB::Util.html_escape(segment)
      index.odd? ? "<mark>#{escaped}</mark>" : escaped
    end.join.html_safe # rubocop:disable Rails/OutputSafety -- every segment is escaped above
  end

  # @return [String] the search page URL for +filters+ plus +overrides+ (blank values dropped)
  def search_page_path(search, **overrides)
    filters = search.filters.merge(include_obsolete: (search.filters[:include_obsolete] ? "1" : nil))
    search_path({ q: search.query, mode: (search.mode unless search.mode == "auto") }.merge(filters, overrides).compact_blank)
  end

  private

  def snippet_window(text, tokens)
    return text if text.length <= SNIPPET_LENGTH

    first_hit = Array(tokens).filter_map { |token| text.downcase.index(token.to_s.downcase) }.min || 0
    start = [ first_hit - (SNIPPET_LENGTH / 3), 0 ].max
    window = text[start, SNIPPET_LENGTH]
    "#{'…' if start.positive?}#{window}#{'…' if start + SNIPPET_LENGTH < text.length}"
  end
end
