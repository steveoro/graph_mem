# frozen_string_literal: true

require "fileutils"

namespace :db do
  desc "Dump the current database to a timestamped backup file"
  task dump: :environment do
    db_config = extract_mysql_config
    backup_dir = resolve_backup_dir
    timestamp = Time.current.strftime("%Y%m%d%H%M")
    backup_file = backup_dir.join("#{timestamp}_#{Rails.env}.sql.bz2")

    FileUtils.mkdir_p(backup_dir)

    puts "Dumping database '#{db_config[:database]}' to '#{backup_file}'..."

    mysqldump_cmd = build_mysqldump_command(db_config)
    full_cmd = "#{mysqldump_cmd} | bzip2 > #{backup_file}"

    success = system(full_cmd)

    if success && File.exist?(backup_file) && File.size(backup_file) > 0
      puts "Database dump completed successfully: #{backup_file}"
      prune_old_backups(backup_dir)
    else
      puts "Database dump failed."
      File.delete(backup_file) if File.exist?(backup_file)
      exit 1
    end
  end

  desc "Restore the database from the most recent backup or a specified file (FILE=path)"
  task restore: :environment do
    db_config = extract_mysql_config
    backup_dir = resolve_backup_dir
    backup_file = determine_restore_file(backup_dir)

    unless backup_file && File.exist?(backup_file)
      puts "Backup file not found: #{backup_file || 'No backups available'}"
      exit 1
    end

    puts "Restoring database '#{db_config[:database]}' from '#{backup_file}'..."
    puts "*** THIS WILL DROP THE EXISTING DATABASE '#{db_config[:database]}' ***"

    unless drop_and_create_database(db_config)
      puts "Failed to prepare database for restore."
      exit 1
    end

    mysql_cmd = build_mysql_command(db_config)
    restore_cmd = "bzcat #{backup_file} | #{mysql_cmd}"

    puts "Restoring data..."
    unless system(restore_cmd)
      puts "Failed to restore database."
      exit 1
    end

    puts "Database restore completed successfully."
  end

  desc "List available backup files in the backup folder (newest first)"
  task list_backups: :environment do
    backup_dir = resolve_backup_dir
    backups = find_all_backups(backup_dir)

    if backups.empty?
      puts "No backups found in #{backup_dir}"
    else
      puts "Available backups in #{backup_dir}:"
      backups.each_with_index do |file, index|
        size = (File.size(file) / 1024.0 / 1024.0).round(2)
        mtime = File.mtime(file).strftime("%Y-%m-%d %H:%M:%S")
        puts "  #{index + 1}. #{File.basename(file)} (#{size} MB, #{mtime})"
      end
    end
  end

  namespace :support do
    desc "Initialize SQLite3 support databases (queue, cache, cable) if not already set up"
    task initialize: :environment do
      {
        "queue" => "solid_queue_jobs",
        "cache" => "solid_cache_entries",
        "cable" => "solid_cable_messages"
      }.each do |db_name, check_table|
        ActiveRecord::Tasks::DatabaseTasks.with_temporary_pool_for_each(name: db_name) do |pool|
          if pool.with_connection { |c| c.table_exists?(check_table) }
            puts "#{db_name} database already initialized."
            next
          end

          puts "Initializing #{db_name} database schema..."
          ActiveRecord::Tasks::DatabaseTasks.load_schema(pool.db_config, :ruby)
        end

      rescue ActiveRecord::AdapterNotSpecified, TypeError
        puts "No config for #{db_name} in current environment — skipping."
      end
    end
  end

  def resolve_backup_dir
    backup_path = begin
      AppSettings.backup_folder_path
    rescue StandardError
      nil
    end

    backup_path = "db/backup" if backup_path.blank?

    if Pathname.new(backup_path).absolute?
      Pathname.new(backup_path)
    else
      Rails.root.join(backup_path)
    end
  end

  def find_all_backups(backup_dir)
    return [] unless backup_dir.exist?

    Dir.glob(backup_dir.join("*.sql.bz2"))
       .map { |f| Pathname.new(f) }
       .select { |path| safe_backup_filename?(path.basename.to_s) }
       .sort_by { |path| File.mtime(path) }
       .reverse
  end

  def find_managed_backups_for_env(backup_dir)
    return [] unless backup_dir.exist?

    pattern = "*_#{Rails.env}.sql.bz2"
    Dir.glob(backup_dir.join(pattern))
       .map { |f| Pathname.new(f) }
       .sort_by { |f| f.basename.to_s }
       .reverse
  end

  def safe_backup_filename?(filename)
    return false if filename.blank?
    return false if filename.start_with?(".")
    return false if filename.include?("..")

    filename.match?(BackupFileService::SAFE_BACKUP_FILENAME)
  end

  def determine_restore_file(backup_dir)
    if ENV["FILE"].present?
      file_path = ENV["FILE"]
      return Pathname.new(file_path) if Pathname.new(file_path).absolute?

      return backup_dir.join(file_path)
    end

    find_all_backups(backup_dir).first
  end

  def prune_old_backups(backup_dir)
    keep_max = begin
      AppSettings.backup_keep_max
    rescue StandardError
      10
    end

    backups = find_managed_backups_for_env(backup_dir)
    return if backups.size <= keep_max

    old_backups = backups.drop(keep_max)
    old_backups.each do |file|
      puts "Pruning old backup: #{file.basename}"
      File.delete(file)
    end

    puts "Pruned #{old_backups.size} old backup(s), keeping #{keep_max} most recent."
  end

  def extract_mysql_config
    if ENV["DATABASE_URL"].present?
      uri = URI.parse(ENV["DATABASE_URL"])
      {
        database: uri.path.sub(%r{^/}, ""),
        username: uri.user,
        password: uri.password,
        host: uri.host,
        port: uri.port,
        socket: nil
      }
    else
      rails_config = resolve_db_config
      {
        database: rails_config["database"],
        username: rails_config["username"],
        password: rails_config["password"],
        host: rails_config["host"],
        port: rails_config["port"],
        socket: rails_config["socket"]
      }
    end.tap do |config|
      abort "ERROR: Could not determine database name." if config[:database].blank?
    end
  end

  def build_mysqldump_command(config)
    cmd = "MYSQL_PWD='#{config[:password]}' mariadb-dump"
    cmd += " -h #{config[:host]}" if config[:host].present? && config[:host] != "localhost"
    cmd += " -P #{config[:port]}" if config[:port].present? && config[:port].to_i != 3306
    cmd += " -S #{config[:socket]}" if config[:socket].present?
    cmd += " -u #{config[:username]}" if config[:username].present?
    cmd += " --no-tablespaces --no-create-db"
    cmd += " --single-transaction --routines --triggers --quick"
    cmd += " #{config[:database]}"
    cmd
  end

  def build_mysql_command(config)
    cmd = "MYSQL_PWD='#{config[:password]}' mariadb"
    cmd += " -h #{config[:host]}" if config[:host].present? && config[:host] != "localhost"
    cmd += " -P #{config[:port]}" if config[:port].present? && config[:port].to_i != 3306
    cmd += " -S #{config[:socket]}" if config[:socket].present?
    cmd += " -u #{config[:username]}" if config[:username].present?
    cmd += " #{config[:database]}"
    cmd
  end

  def build_mysql_admin_command(config)
    cmd = "MYSQL_PWD='#{config[:password]}' mariadb"
    cmd += " -h #{config[:host]}" if config[:host].present? && config[:host] != "localhost"
    cmd += " -P #{config[:port]}" if config[:port].present? && config[:port].to_i != 3306
    cmd += " -S #{config[:socket]}" if config[:socket].present?
    cmd += " -u #{config[:username]}" if config[:username].present?
    cmd
  end

  def drop_and_create_database(config)
    admin_cmd = build_mysql_admin_command(config)
    db_name = config[:database]

    puts "Dropping database..."
    drop_cmd = "#{admin_cmd} -e 'DROP DATABASE IF EXISTS `#{db_name}`;'"
    unless system(drop_cmd)
      puts "Warning: Could not drop database (may not exist)"
    end

    puts "Creating database..."
    create_cmd = "#{admin_cmd} -e 'CREATE DATABASE `#{db_name}` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;'"
    system(create_cmd)
  end

  def resolve_db_config
    config = Rails.configuration.database_configuration[Rails.env]
    config = config["primary"] if config.is_a?(Hash) && config.key?("primary")
    config
  end
end
