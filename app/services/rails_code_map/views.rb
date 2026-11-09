# frozen_string_literal: true

class RailsCodeMap
  # The view entries of a Rails code map (1.75.0): one View entry per folder of templates under
  # app/views (named by its path, so it can't collide with a concept name), and one Layout entry
  # per file under app/views/layouts. Files directly in app/views belong to no folder and are skipped.
  #
  #   views = RailsCodeMap::Views.entries("/path/to/project")
  #   views.map(&:name) # => ["app/views/goggles_db/swimmers", "app/views/layouts/application.html.haml"]
  #   views.first.facts # => ["Templates: _form.html.haml, index.html.haml, show.html.haml"]
  module Views
    VIEWS_DIR = "app/views"
    LAYOUTS_DIR = "layouts"
    # The most template names a View entry's fact lists.
    MAX_TEMPLATES = 20

    module_function

    # @param root [String] the project folder
    # @param keep [#call, nil] `keep.call(absolute_path)` false skips a file
    # @param limit [Integer] the most files read
    # @return [Array(Array<Entry>, Boolean)] the entries (folders, then layouts, by path) and whether
    #   every file under app/views was listed (false past `limit`)
    def entries(root, keep: nil, limit: RailsCodeMap::MAX_FILES)
      base = File.join(root, VIEWS_DIR)
      return [ [], true ] unless File.directory?(base)

      files = Dir.glob("**/*", base: base).sort.select do |rel|
        path = File.join(base, rel)
        File.file?(path) && !File.symlink?(path) && (keep.nil? || keep.call(path))
      end
      complete = files.size <= limit
      layouts, templates = files.first(limit).partition { |rel| rel.start_with?("#{LAYOUTS_DIR}/") }

      folders = templates.select { |rel| rel.include?("/") }.group_by { |rel| File.dirname(rel) }
      [ folders.sort.map { |folder, rels| folder_entry(folder, rels) } + layouts.map { |rel| layout_entry(rel) }, complete ]
    end

    # @param name [String] a View or Layout entry's name
    # @return [Array<String>] the constants that render it, most likely first: a folder's
    #   controller or mailer, a layout's controller or mailer (`app/views/goggles_db/swimmers` =>
    #   ["GogglesDb::SwimmersController", "GogglesDb::Swimmers"])
    def owner_names(name)
      path = name.delete_prefix("#{VIEWS_DIR}/").delete_prefix("#{LAYOUTS_DIR}/")
      path = path.sub(/\.[^\/]*\z/, "") if name.start_with?("#{VIEWS_DIR}/#{LAYOUTS_DIR}/")
      camel = path.camelize
      [ "#{camel}Controller", "#{camel}Mailer", camel ]
    end

    def folder_entry(folder, rels)
      name = "#{VIEWS_DIR}/#{folder}"
      files = rels.map { |rel| "#{VIEWS_DIR}/#{rel}" }
      templates = rels.map { |rel| File.basename(rel) }.sort
      listed = templates.first(MAX_TEMPLATES).join(", ")
      listed += " (and #{templates.size - MAX_TEMPLATES} more)" if templates.size > MAX_TEMPLATES
      Entry.new(name: name, type: "View", kind: "View", files: files, facts: [ "Templates: #{listed}" ], aliases: [],
                keys: ([ name ] + files).flat_map { |text| RailsCodeMap.keys_for(text) }.uniq, superclass: nil)
    end

    def layout_entry(rel)
      name = "#{VIEWS_DIR}/#{rel}"
      Entry.new(name: name, type: "Layout", kind: "Layout", files: [ name ], facts: [ "Defined at #{name}" ], aliases: [],
                keys: RailsCodeMap.keys_for(name), superclass: nil)
    end
    private_class_method :folder_entry, :layout_entry
  end
end
