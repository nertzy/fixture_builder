# frozen_string_literal: true

module FixtureBuilder
  class Builder
    include Delegations::Namer
    include Delegations::Configuration

    def initialize(configuration, namer, builder_block)
      @configuration = configuration
      @namer = namer
      @builder_block = builder_block
    end

    def generate!
      say 'Building fixtures'
      clean_out_old_data
      create_fixture_objects
      names_from_ivars!
      write_data_to_files
      after_build&.call
    end

    protected

    def create_fixture_objects
      load_legacy_fixtures if legacy_fixtures.present?
      surface_errors { instance_eval(&@builder_block) }
    end

    def load_legacy_fixtures
      legacy_fixtures.each do |fixture_file|
        fixtures = fixtures_class.create_fixtures(File.dirname(fixture_file), File.basename(fixture_file, '.*'))
        populate_custom_names(fixtures)
      end
    end

    # Rails 3.0 and 3.1+ support
    def fixtures_class
      if defined?(ActiveRecord::FixtureSet)
        ActiveRecord::FixtureSet
      elsif defined?(ActiveRecord::Fixtures)
        ActiveRecord::Fixtures
      else
        ::Fixtures
      end
    end

    def surface_errors
      yield
    rescue Object => e
      puts
      say 'There was an error building fixtures', e.inspect
      puts
      puts e.backtrace
      puts
      exit!
    end

    def names_from_ivars!
      instance_values.each do |var, value|
        name(var, value) if value.is_a? ActiveRecord::Base
      end
    end

    def write_data_to_files
      delete_yml_files
      dump_empty_fixtures_for_all_tables if write_empty_files
      dump_tables
    end

    def clean_out_old_data
      delete_tables
      delete_yml_files
    end

    def delete_tables
      ActiveRecord::Base.connection.disable_referential_integrity do
        tables.each do |t|
          ActiveRecord::Base.connection.delete(format(delete_sql,
                                                      table: ActiveRecord::Base.connection.quote_table_name(t)))
        end
      end
    end

    def delete_yml_files
      FileUtils.rm(*tables.map { |t| fixture_file(t) })
    rescue StandardError
      nil
    end

    def say(*messages)
      puts messages.map { |message| "=> #{message}" }
    end

    def dump_empty_fixtures_for_all_tables
      tables.each do |table_name|
        write_fixture_file({}, table_name)
      end
    end

    def dump_tables
      default_date_format = Date::DATE_FORMATS[:default]
      Date::DATE_FORMATS[:default] = Date::DATE_FORMATS[:db]
      begin
        fixtures = tables.inject([]) do |files, table_name|
          table_klass = begin
            table_name.classify.constantize
          rescue StandardError
            nil
          end
          if table_klass && table_klass < ActiveRecord::Base
            rows = table_klass.unscoped do
              table_klass.order(:id).all.collect do |obj|
                table_klass.column_names.each_with_object({}) do |attr_name, hash|
                  value = serialize_attribute(table_klass, attr_name, obj)
                  hash[attr_name] = value unless value.nil?
                end
              end
            end
          else
            rows = ActiveRecord::Base.connection.select_all(format(select_sql,
                                                                   table: ActiveRecord::Base.connection.quote_table_name(table_name)))
          end
          next files if rows.empty?

          fixture_data = rows.inject({}) do |hash, record|
            hash.merge(record_name(record, table_name) => record)
          end

          write_fixture_file fixture_data, table_name

          files + [File.basename(fixture_file(table_name))]
        end
      ensure
        Date::DATE_FORMATS[:default] = default_date_format
      end
      say "Built #{fixtures.to_sentence}"
    end

    def write_fixture_file(fixture_data, table_name)
      File.open(fixture_file(table_name), 'w') do |file|
        file.write fixture_data.to_yaml
      end
    end

    def fixture_file(table_name)
      fixtures_dir("#{table_name}.yml")
    end

    # Serialize an attribute value using its type's serialize method.
    # This ensures YAML stores database-compatible primitives that Rails
    # can reload properly through the type system.
    def serialize_attribute(klass, attr_name, obj)
      return obj.read_attribute_before_type_cast(attr_name) unless klass.respond_to?(:type_for_attribute)

      type = klass.type_for_attribute(attr_name)
      return obj.read_attribute_before_type_cast(attr_name) if type.nil?

      ruby_value = obj.read_attribute(attr_name)
      return nil if ruby_value.nil?

      # For JSONB columns with JSON types, return the Hash/Array representation.
      # ActiveRecord::Type::Json#serialize returns a JSON string, but YAML
      # fixtures need the raw Hash/Array for JSONB columns to load correctly.
      # For TEXT columns with JSON types, we still want the JSON string.
      column = klass.columns_hash[attr_name]
      is_jsonb_column = column && %w[jsonb json].include?(column.sql_type)

      if type.is_a?(ActiveRecord::Type::Json) && is_jsonb_column
        # Try as_json first (works for ActiveModel objects), then to_h, then the value itself
        if ruby_value.respond_to?(:as_json)
          return ruby_value.as_json
        elsif ruby_value.respond_to?(:to_h)
          return ruby_value.to_h
        else
          return ruby_value
        end
      end

      type.serialize(ruby_value)
    end
  end
end
