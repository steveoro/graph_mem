# frozen_string_literal: true

# Temporary file storage for an uploaded graph_mem-sql script between its preview and its execute, so
# nothing of it goes into the cookie session: the script itself (`<id>_script.sql`), what the upload was
# (`<id>_meta.json`) and its dry-run preview (`<id>_preview.json`), under a fresh UUID.
# (The JSON upload's data, matches and stats went with the JSON import's retirement in 1.94.0.)
#
#   session_id = ImportSession.create_sql(upload, meta: { file_name: "synth_prj.sql", producer: "graph_mem-sql" })
#   ImportSession.store_preview(session_id, preview)
#   ImportSession.load_preview(session_id) # => { "summary" => { … }, … }
#   ImportSession.cleanup(session_id)
class ImportSession
  TEMP_DIR = Rails.root.join("tmp", "data_exchange")

  class << self
    # Check if an import session exists
    # @param session_id [String] The session ID
    # @return [Boolean]
    def exists?(session_id)
      sql?(session_id)
    end

    # Stores an uploaded graph_mem-sql script under a fresh id (copied as it is, never parsed here)
    # @param io [#read] the upload
    # @param meta [Hash] what the upload was (file_name, producer)
    # @return [String] the session ID
    def create_sql(io, meta:)
      session_id = SecureRandom.uuid
      ensure_temp_dir
      File.open(sql_path(session_id), "wb") { |file| IO.copy_stream(io, file) }
      write_file(session_id, "meta", meta)
      session_id
    end

    # @param session_id [String] The session ID
    # @return [String] where the session's script is (it may not exist)
    def sql_path(session_id)
      File.join(TEMP_DIR, "#{session_id}_script.sql")
    end

    # @param session_id [String] The session ID
    # @return [Boolean] the session holds a graph_mem-sql script
    def sql?(session_id)
      session_id.present? && File.exist?(sql_path(session_id))
    end

    # Store a graph_mem-sql script's dry-run preview
    # @param session_id [String] The session ID
    # @param preview [Hash]
    def store_preview(session_id, preview)
      write_file(session_id, "preview", preview)
    end

    # Load a graph_mem-sql script's dry-run preview, with string keys (as operation details have)
    # @param session_id [String] The session ID
    # @return [Hash, nil]
    def load_preview(session_id)
      path = path_for(session_id, "preview")
      File.exist?(path) ? JSON.parse(File.read(path)) : nil
    end

    # Load what the upload was (file_name, producer)
    # @param session_id [String] The session ID
    # @return [Hash] symbol keys; empty when the session has no meta file
    def load_meta(session_id)
      read_file(session_id, "meta") || {}
    end

    # Clean up all files for a session
    # @param session_id [String] The session ID
    def cleanup(session_id)
      return if session_id.blank?

      %w[meta preview].each do |suffix|
        FileUtils.rm_f(path_for(session_id, suffix))
      end
      FileUtils.rm_f(sql_path(session_id))
    end

    # Clean up old sessions (older than specified age)
    # @param max_age [Integer] Maximum age in seconds (default: 24 hours)
    def cleanup_old_sessions(max_age: 24.hours.to_i)
      return unless Dir.exist?(TEMP_DIR)

      cutoff_time = Time.current - max_age

      Dir.glob(File.join(TEMP_DIR, "*.{json,sql}")).each do |file|
        if File.mtime(file) < cutoff_time
          FileUtils.rm_f(file)
        end
      end
    end

    private

    def ensure_temp_dir
      FileUtils.mkdir_p(TEMP_DIR)
    end

    def path_for(session_id, suffix)
      File.join(TEMP_DIR, "#{session_id}_#{suffix}.json")
    end

    def write_file(session_id, suffix, data)
      File.write(path_for(session_id, suffix), data.to_json)
    end

    def read_file(session_id, suffix)
      path = path_for(session_id, suffix)
      return nil unless File.exist?(path)

      JSON.parse(File.read(path), symbolize_names: true)
    rescue JSON::ParserError => e
      Rails.logger.error "ImportSession: Failed to parse #{suffix} file: #{e.message}"
      nil
    end
  end
end
