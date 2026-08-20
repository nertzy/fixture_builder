# frozen_string_literal: true

require 'active_support/core_ext'
require 'active_support/core_ext/string'
require 'digest'
require 'fileutils'
require 'hashdiff'
require 'tempfile'
require 'thread'

module FixtureBuilder
  Differ = if Object.const_defined?(:Hashdiff)
             # hashdiff version >= 1.0.0
             Hashdiff
           else
             HashDiff
           end

  class Configuration
    include Delegations::Namer

    GenerationMutexState = Struct.new(:pid, :guard, :mutexes, keyword_init: true)
    private_constant :GenerationMutexState

    @generation_mutex_state = GenerationMutexState.new(
      pid: Process.pid,
      guard: Mutex.new,
      mutexes: {}
    )

    class << self
      private

      def generation_mutex_for(lock_path)
        state = @generation_mutex_state
        if state.nil? || state.pid != Process.pid
          state = GenerationMutexState.new(pid: Process.pid, guard: Mutex.new, mutexes: {})
          @generation_mutex_state = state
        end

        state.guard.synchronize do
          state.mutexes[lock_path] ||= Mutex.new
        end
      end
    end

    MANIFEST_VERSION = 2

    ACCESSIBLE_ATTRIBUTES = %i[select_sql delete_sql skip_tables files_to_check record_name_fields
                               fixture_builder_file fixture_directory after_build legacy_fixtures model_name_procs
                               write_empty_files].freeze
    attr_accessor(*ACCESSIBLE_ATTRIBUTES)

    SCHEMA_FILES = ['db/schema.rb', 'db/development_structure.sql', 'db/test_structure.sql',
                    'db/production_structure.sql'].freeze

    def initialize(opts = {})
      @namer = Namer.new(self)
      @use_sha1_digests = opts[:use_sha1_digests] || false
      @file_hashes = file_hashes
      @write_empty_files = true
    end

    def include(*args)
      class_eval do
        args.each do |arg|
          include arg
        end
      end
    end

    def factory(&block)
      self.files_to_check += @legacy_fixtures.to_a
      return unless rebuild_fixtures_preflight?

      with_generation_lock do
        @file_hashes = file_hashes
        locked_file_hashes = @file_hashes
        next unless rebuild_fixtures?

        invalidate_config
        @builder = Builder.new(self, @namer, block).generate!
        @file_hashes = locked_file_hashes
        write_config
      end
    end

    def select_sql
      @select_sql ||= 'SELECT * FROM %<table>s'
    end

    def select_sql=(sql)
      if sql =~ /%s/
        ActiveSupport::Deprecation.warn("Passing '%s' into select_sql is deprecated. Please use '%<table>s' instead.",
                                        caller)
        sql = sql.sub(/%s/, '%<table>s')
      end
      @select_sql = sql
    end

    def delete_sql
      @delete_sql ||= 'DELETE FROM %<table>s'
    end

    def delete_sql=(sql)
      if sql =~ /%s/
        ActiveSupport::Deprecation.warn("Passing '%s' into delete_sql is deprecated. Please use '%<table>s' instead.",
                                        caller)
        sql = sql.sub(/%s/, '%<table>s')
      end
      @delete_sql = sql
    end

    def skip_tables
      @skip_tables ||= %w[schema_migrations ar_internal_metadata]
    end

    def files_to_check
      @files_to_check ||= schema_definition_files
    end

    def schema_definition_files
      Dir['db/*'].each_with_object([]) do |file, result|
        result << file if SCHEMA_FILES.include?(file)
      end
    end

    def files_to_check=(files)
      @files_to_check = files
      @file_hashes = file_hashes
      @files_to_check
    end

    def record_name_fields
      @record_name_fields ||= %w[unique_name display_name name title username login]
    end

    def fixture_builder_file
      @fixture_builder_file ||= ::Rails.root.join('tmp', 'fixture_builder.yml')
    end

    def fixture_builder_lock_file
      "#{File.expand_path(fixture_builder_file.to_s)}.lock"
    end

    def name_model_with(model_class, &block)
      @namer.name_model_with(model_class, &block)
    end

    def tables
      ActiveRecord::Base.connection.tables - skip_tables
    end

    def fixture_directory
      @fixture_directory ||= FixturesPath.absolute_rails_fixtures_path
    end

    def fixtures_dir(path = '')
      File.expand_path(File.join(fixture_directory, path))
    end

    private

    def file_hashes
      files_to_check.each_with_object({}) do |filename, hash|
        hash[filename.to_s] = file_digest(filename)
      end
    end

    def fixture_hashes
      pattern = File.join(fixture_directory.to_s, '*.yml')
      Dir.glob(pattern).sort.each_with_object({}) do |filename, hash|
        hash[File.basename(filename)] = file_digest(filename)
      end
    end

    def file_digest(filename)
      algorithm = @use_sha1_digests ? Digest::SHA1 : Digest::MD5
      algorithm.file(filename.to_s).hexdigest
    end

    def read_config
      YAML.safe_load_file(fixture_builder_file)
    end

    def rebuild_fixtures_preflight?
      rebuild_fixtures?(announce: false)
    rescue Errno::ENOENT
      true
    end

    def manifest_status(manifest)
      return :legacy if legacy_manifest?(manifest)
      return :unsupported if unsupported_manifest?(manifest)
      return :current if current_manifest?(manifest)

      :invalid
    end

    def legacy_manifest?(manifest)
      manifest.is_a?(Hash) && !manifest.key?('version') && digest_hash?(manifest)
    end

    def unsupported_manifest?(manifest)
      manifest.is_a?(Hash) && manifest['version'].is_a?(Integer) &&
        manifest['version'] != MANIFEST_VERSION
    end

    def current_manifest?(manifest)
      expected_keys = %w[fixtures sources version]
      manifest.is_a?(Hash) && manifest.keys.length == expected_keys.length &&
        expected_keys.all? { |key| manifest.key?(key) } &&
        manifest['version'].is_a?(Integer) && manifest['version'] == MANIFEST_VERSION &&
        digest_hash?(manifest['sources']) && digest_hash?(manifest['fixtures'])
    end

    def digest_hash?(hash)
      hash.is_a?(Hash) && hash.all? do |key, digest|
        key.is_a?(String) && digest.is_a?(String)
      end
    end

    def invalidate_config
      FileUtils.rm(fixture_builder_file) if File.exist?(fixture_builder_file)
    end

    def with_generation_lock
      lock_path = fixture_builder_lock_file
      mutex = self.class.send(:generation_mutex_for, lock_path)
      waiting = false
      locked = mutex.try_lock
      unless locked
        puts "=> waiting for fixture generation lock #{lock_path}"
        waiting = true
        mutex.lock
        locked = true
      end

      begin
        FileUtils.mkdir_p(File.dirname(lock_path))
        File.open(lock_path, File::RDWR | File::CREAT, 0o644) do |file|
          unless file.flock(File::LOCK_EX | File::LOCK_NB)
            puts "=> waiting for fixture generation lock #{lock_path}" unless waiting
            file.flock(File::LOCK_EX)
          end

          begin
            yield
          ensure
            file.flock(File::LOCK_UN)
          end
        end
      ensure
        mutex.unlock if locked
      end
    end

    def write_config
      manifest = {
        'version' => MANIFEST_VERSION,
        'sources' => @file_hashes,
        'fixtures' => fixture_hashes
      }
      destination = fixture_builder_file.to_s
      directory = File.dirname(destination)
      FileUtils.mkdir_p(directory)
      Tempfile.create(['fixture_builder', '.yml'], directory) do |file|
        temporary_path = file.path
        file.write(YAML.dump(manifest))
        file.flush
        file.fsync
        file.close
        File.rename(temporary_path, destination)
      end
    end

    def rebuild_fixtures?(announce: true)
      unless ::File.exist?(fixture_builder_file)
        if announce
          puts "=> rebuilding fixtures because fixture_builder config file #{fixture_builder_file} does not exist"
        end
        return true
      end

      manifest = read_config
      case manifest_status(manifest)
      when :legacy
        if announce
          puts "=> rebuilding fixtures because fixture_builder config file #{fixture_builder_file} uses a legacy flat manifest format"
        end
        return true
      when :unsupported
        if announce
          puts "=> rebuilding fixtures because fixture_builder config file #{fixture_builder_file} uses unsupported manifest version #{manifest['version'].inspect}"
        end
        return true
      when :invalid
        if announce
          puts "=> rebuilding fixtures because fixture_builder config file #{fixture_builder_file} has an invalid or malformed current manifest shape"
        end
        return true
      end

      if @file_hashes != manifest['sources']
        print_hash_diff('source files have changed', @file_hashes, manifest['sources']) if announce
        return true
      elsif fixture_hashes != manifest['fixtures']
        if announce
          print_hash_diff('generated fixture output has changed', fixture_hashes, manifest['fixtures'])
        end
        return true
      end
      false
    end

    def print_hash_diff(reason, hashes_from_disk, hashes_from_config)
      puts "=> rebuilding fixtures because #{reason} (see http://www.rubydoc.info/gems/hashdiff for diff syntax):"
      Differ.diff(hashes_from_disk, hashes_from_config).each do |diff|
        print '   '
        p diff
      end
    end
  end
end
