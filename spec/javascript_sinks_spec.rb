# frozen_string_literal: true

# UI-0 (F1): guard against re-introducing innerHTML sinks with template-literal interpolation.
# Any assignment of the form:  el.innerHTML = `...${...`
# is caught by this spec. Static assignments (no ${) are fine.
RSpec.describe "JavaScript innerHTML sinks" do
  let(:js_files) do
    Dir.glob(Rails.root.join("app/javascript/**/*.js")).sort
  end

  it "has no innerHTML assigned from template literals with interpolation" do
    violations = []

    js_files.each do |path|
      relative = Pathname.new(path).relative_path_from(Rails.root)
      File.readlines(path).each_with_index do |line, idx|
        # Match:  innerHTML = `   or  innerHTML=`   followed later by ${
        # We require both the backtick-open AND the interpolation on the same line.
        if line.match?(/innerHTML\s*=\s*`[^`]*\$\{/)
          violations << "#{relative}:#{idx + 1}: #{line.strip}"
        end
      end
    end

    expect(violations).to be_empty,
      "Found innerHTML sink(s) with template-literal interpolation " \
      "(replace with DOM construction via lib/dom.js):\n\n#{violations.join("\n")}"
  end
end
