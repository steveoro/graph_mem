# frozen_string_literal: true

# UI-0 (F1): guard against re-introducing innerHTML sinks with template-literal interpolation.
# Any assignment of the form:  el.innerHTML = `...${...`
# is caught by this spec — even when the backtick-open and the interpolation span
# multiple lines. Static assignments (no ${) are fine.
RSpec.describe "JavaScript innerHTML sinks" do
  let(:js_files) do
    Dir.glob(Rails.root.join("app/javascript/**/*.js")).sort
  end

  it "has no innerHTML assigned from template literals with interpolation" do
    violations = []

    js_files.each do |path|
      relative = Pathname.new(path).relative_path_from(Rails.root)
      source = File.read(path)
      # Multiline scan: find every innerHTML = `...` template literal (may span
      # lines) and flag it when it contains at least one ${...} interpolation.
      source.scan(/innerHTML\s*=\s*`[^`]*\$\{[^`]*`/m) do
        # Locate the line number of the match start.
        match_start = Regexp.last_match.begin(0)
        line_number = source[0...match_start].count("\n") + 1
        first_line  = source[match_start..].lines.first&.strip
        violations << "#{relative}:#{line_number}: #{first_line}"
      end
    end

    expect(violations).to be_empty,
      "Found innerHTML sink(s) with template-literal interpolation " \
      "(replace with DOM construction via lib/dom.js):\n\n#{violations.join("\n")}"
  end
end
