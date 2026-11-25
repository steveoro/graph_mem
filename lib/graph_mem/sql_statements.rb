# frozen_string_literal: true

module GraphMem
  # Splits a SQL script into statements the way the `mariadb` client reads the scripts this app
  # runs through its own connection (db/structure.sql, the graph_mem-sql export template): line by
  # line, following `DELIMITER` lines, a statement ending on the first line that ends with the
  # current delimiter. Outside a statement, blank lines, `--` comment lines and lines matching
  # `skip:` are dropped. Shared by ScanProfile::StructureLoader and SqlExport::Template.
  #
  #   GraphMem::SqlStatements.split("SET @a = 1;\nDELIMITER //\nBEGIN NOT ATOMIC SELECT 1; END//\nDELIMITER ;\n")
  #   # => ["SET @a = 1", "BEGIN NOT ATOMIC SELECT 1; END"]
  module SqlStatements
    module_function

    # @param sql [String]
    # @param skip [Regexp, nil] more lines to drop outside a statement (matched on the stripped line)
    # @return [Array<String>] the statements, stripped, without their delimiters
    def split(sql, skip: nil)
      delimiter = ";"
      buffer = +""
      sql.each_line.with_object([]) do |line, list|
        stripped = line.strip
        next if buffer.empty? && (stripped.empty? || stripped.start_with?("--") || (skip && stripped.match?(skip)))

        if buffer.empty? && (match = stripped.match(/\ADELIMITER\s+(\S+)\z/i))
          delimiter = match[1]
          next
        end

        buffer << line
        next unless stripped.end_with?(delimiter)

        list << buffer.strip.delete_suffix(delimiter).strip
        buffer = +""
      end
    end
  end
end
