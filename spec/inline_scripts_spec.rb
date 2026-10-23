# frozen_string_literal: true

# mcp plan PR-2 §2.20 item 2: views must not carry inline scripts the CSP can't nonce.
# Behaviour belongs in a Stimulus controller (app/javascript/controllers); an inline
# <script> written in a view must pass `nonce: true` through a helper instead.
RSpec.describe "Inline scripts in views" do
  let(:view_files) { Dir.glob(Rails.root.join("app/views/**/*.{haml,erb}")).sort }

  it "has no HAML :javascript filters or literal <script> tags" do
    violations = view_files.flat_map do |path|
      relative = Pathname.new(path).relative_path_from(Rails.root)
      File.readlines(path).each_with_index.filter_map do |line, index|
        "#{relative}:#{index + 1}: #{line.strip}" if line.match?(/^\s*:javascript\b|^\s*%script\b|<script\b/i)
      end
    end

    expect(violations).to be_empty,
      "Found inline script(s) (move them to a Stimulus controller):\n\n#{violations.join("\n")}"
  end
end
