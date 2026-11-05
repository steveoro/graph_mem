# frozen_string_literal: true

module GraphMem
  module ScanProfile
    # Loads db/structure.sql into the profiler's throwaway database through the open connection,
    # statement by statement (F-3b), so no `mysql` client process is started. It follows the dump's
    # DELIMITER lines (the embedding triggers use `;;`), skips the client-only sandbox-mode line,
    # and drops the triggers' DEFINER clause so the connecting user owns them.
    #
    #   StructureLoader.statements(File.read("db/structure.sql")).size # => 180-ish
    #   StructureLoader.load!(connection, Rails.root.join("db/structure.sql"))
    module StructureLoader
      DEFINER = %r{/\*!50017 DEFINER=`[^`]*`@`[^`]*`\s*\*/\s*}
      CLIENT_ONLY = %r{\A/\*M!999999\\-}

      module_function

      # @param sql [String] a mysqldump / mariadb-dump structure file
      # @return [Array<String>] the statements, without their delimiters
      def statements(sql)
        delimiter = ";"
        buffer = +""
        sql.each_line.with_object([]) do |line, list|
          stripped = line.strip
          next if buffer.empty? && (stripped.empty? || stripped.start_with?("--") || stripped.match?(CLIENT_ONLY))

          if buffer.empty? && (match = stripped.match(/\ADELIMITER\s+(\S+)\z/i))
            delimiter = match[1]
            next
          end

          buffer << line
          next unless stripped.end_with?(delimiter)

          list << buffer.strip.delete_suffix(delimiter).strip.gsub(DEFINER, "")
          buffer = +""
        end
      end

      # @param connection [ActiveRecord::ConnectionAdapters::AbstractAdapter] the throwaway database's
      # @param path [String, Pathname] db/structure.sql
      # @return [Integer] the statements run
      def load!(connection, path)
        list = statements(File.read(path.to_s))
        list.each { |statement| connection.execute(statement) }
        list.size
      end
    end
  end
end
