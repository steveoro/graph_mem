# frozen_string_literal: true

class ProjectScanner
  # The deterministic fallback of ProjectScanner (moved from it in F-3): the manifests and the
  # top-level directories, with the README's title and first lines. Private methods of
  # ProjectScanner; they read its instance variables.
  module DeterministicExtraction
    private

    def deterministic_extraction
      project_name = @project_name.presence || project_name_from_readme || File.basename(@project_root)
      description = project_description_from_readme || "Project scanned from #{@project_root} (LLM summarization unavailable)"
      architecture = []

      manifests = @discovered_files.select { |file| ChunkPlanner.manifest_file?(file) }
      manifests.each do |file|
        relative = Pathname.new(file).relative_path_from(@file_filter.root).to_s
        next if relative.blank?

        content_preview = file_preview(file, 400)
        architecture << {
          "entity" => {
            "name" => File.basename(relative),
            "type" => "Configuration",
            "aliases" => [],
            "description" => "Project manifest file: #{relative}"
          },
          "observations" => [
            "Manifest file #{relative} contains: #{content_preview}"
          ],
          "relations" => [
            { "to" => project_name, "type" => "part_of", "confidence" => 0.9 }
          ]
        }
      end

      top_level_directories.each do |dir|
        architecture << {
          "entity" => {
            "name" => dir,
            "type" => "Component",
            "aliases" => [],
            "description" => "Top-level project directory: #{dir}/"
          },
          "observations" => [
            "Top-level directory: #{dir}/"
          ],
          "relations" => [
            { "to" => project_name, "type" => "part_of", "confidence" => 0.9 }
          ]
        }
      end

      {
        "project" => {
          "name" => project_name,
          "aliases" => @aliases,
          "description" => description
        },
        "architecture" => architecture
      }
    end

    def project_name_from_readme
      readme = @discovered_files.find { |file| File.basename(file).downcase.start_with?("readme") }
      return nil unless readme

      content = safe_read(readme)
      content.lines.map(&:strip).find { |line| line =~ /^(#|##)\s+(.+)$/ }&.match(/^(#|##)\s+(.+)$/)&.[](2)
    end

    def project_description_from_readme
      readme = @discovered_files.find { |file| File.basename(file).downcase.start_with?("readme") }
      return nil unless readme

      lines = safe_read(readme).lines.map(&:strip).reject { |line| line.blank? || line.start_with?("#") }
      lines.first(2).join(" ").presence
    end

    def top_level_directories
      return [] unless Dir.exist?(@project_root)

      Dir.children(@project_root).select do |child|
        full = File.join(@project_root, child)
        # lstat: a symlinked entry is never followed, so it isn't listed as a directory.
        File.lstat(full).directory? && !child.start_with?(".") && child != "node_modules" && child != "vendor"
      rescue SystemCallError
        # Removed between Dir.children and lstat: leave that entry out, keep the others.
        false
      end
    rescue SystemCallError
      []
    end

    def file_preview(file, max_bytes)
      text = safe_read(file, max_bytes)
      text.squish.truncate(max_bytes, separator: /\s/)
    end

    def safe_read(file, max_bytes = MAX_FILE_BYTES)
      return "" unless File.readable?(file)

      File.binread(file, [ File.size(file), max_bytes ].min)
        .force_encoding("UTF-8")
        .encode("UTF-8", invalid: :replace, undef: :replace)
    rescue SystemCallError
      ""
    end
  end
end
