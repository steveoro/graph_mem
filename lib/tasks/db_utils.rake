require "yaml"
require "rails"

namespace :db do
  desc "Dump the development database to db/backup/graph_mem.sql.bz2"
  task dump: :environment do
    # Prepare & check configuration:
    db_name, cmd_params = extract_cmd_params
    backup_dir = Rails.root.join("db", "backup")
    backup_file = backup_dir.join("#{db_name}.sql.bz2")

    # Ensure backup directory exists (it should, we created it earlier)
    FileUtils.mkdir_p(backup_dir)

    puts "Dumping database '#{db_name}' to '#{backup_file}'..."

    # Build base mysql command parts
    mysqldump_cmd = "mysqldump" + cmd_params
    mysqldump_cmd += " --no-tablespaces" # Often needed for RDS compatibility/simpler dumps
    mysqldump_cmd += " #{db_name}"

    # Pipe through bzip2
    full_cmd = "#{mysqldump_cmd} | bzip2 > #{backup_file}"

    success = system(full_cmd)

    if success
      puts "Database dump completed successfully."
    else
      puts "Database dump failed."
      # Consider raising an error: raise 'Database dump failed!'
    end
  end
  # ---------------------------------------------------------------------------

  desc "Restore the development database from db/backup/graph_mem.sql.bz2 (Drops existing DB!)"
  task restore: :environment do
    # Prepare & check configuration:
    db_name, cmd_params = extract_cmd_params
    backup_dir = Rails.root.join("db", "backup")
    backup_file = backup_dir.join("#{db_name}.sql.bz2")

    unless File.exist?(backup_file)
      puts "Backup file not found: #{backup_file}"
      exit 1
    end

    puts "Restoring database '#{db_name}' from '#{backup_file}'..."
    puts "*** THIS WILL DROP THE EXISTING DATABASE '#{db_name}' ***"

    # Build base mysql command parts
    mysql_base_cmd = "mysql" + cmd_params

    # Commands to drop and create
    drop_cmd = "#{mysql_base_cmd} -e 'DROP DATABASE IF EXISTS \`#{db_name}\`;'"
    create_cmd = "#{mysql_base_cmd} -e 'CREATE DATABASE \`#{db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;'"
    # Restore command (pipe bzcat output)
    restore_cmd = "bzcat #{backup_file} | #{mysql_base_cmd} #{db_name}"

    puts "Dropping database..."
    unless system(drop_cmd)
      puts "Failed to drop database."
      exit 1
    end

    puts "Creating database..."
    unless system(create_cmd)
      puts "Failed to create database."
      exit 1
    end

    puts "Restoring data..."
    unless system(restore_cmd)
      puts "Failed to restore database."
      exit 1
    end

    puts "Database restore completed successfully."
  end
  # ---------------------------------------------------------------------------

  # Returns an array with the database name and a string with the common parameters for the mysql and mysqldump commands
  def extract_cmd_params
    # Prepare & check configuration:
    rails_config  = Rails.configuration
    db_name       = rails_config.database_configuration[Rails.env]['database']
    db_user       = rails_config.database_configuration[Rails.env]['username']
    db_pass       = rails_config.database_configuration[Rails.env]['password']
    db_host       = rails_config.database_configuration[Rails.env]['host']
    db_socket     = rails_config.database_configuration[Rails.env]['socket']

    result = " -u #{db_user}"
    result += " -p'#{db_pass}'" if db_pass.present?
    result += " -h #{db_host}" if db_host.present? && db_host != "localhost"
    result += " -S #{db_socket}" if db_socket.present?
    [db_name, result]
  end
  # ---------------------------------------------------------------------------
end
