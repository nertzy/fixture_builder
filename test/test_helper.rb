# frozen_string_literal: true

require 'rubygems'
require 'bundler/setup'
require 'test/unit'

class Rails
  def self.root
    Pathname.new(File.join(File.dirname(__FILE__), '..'))
  end

  def self.env
    'test'
  end
end

def test_path(glob)
  File.join(Rails.root, 'test', glob)
end

require 'active_support/concern'
require 'active_record'
require 'active_record/fixtures'

def create_fixtures(*table_names, &block)
  ActiveRecord::FixtureSet.create_fixtures(test_path('fixtures'), table_names, {}, &block)
end

require 'sqlite3'
require 'fixture_builder'

class WizardData
  attr_reader :level, :title, :allies

  def initialize(hash = {})
    @level = hash['level']
    @title = hash['title']
    @allies = hash['allies'] || []
  end

  def to_h
    { 'level' => level, 'title' => title, 'allies' => allies }
  end

  def inspect
    "#<WizardData level=#{level} title=#{title.inspect} allies=#{allies.inspect}>"
  end

  def ==(other)
    other.is_a?(WizardData) &&
      level == other.level &&
      title == other.title &&
      allies == other.allies
  end
end

class WizardDataType < ActiveRecord::Type::Json
  def deserialize(value)
    hash = super
    hash ? WizardData.new(hash) : nil
  end

  def serialize(value)
    case value
    when WizardData then super(value.to_h)
    when Hash then super(value)
    else super
    end
  end
end

class TagList
  attr_reader :tags

  def initialize(tags = [])
    @tags = Array(tags).map(&:to_s).uniq.sort
  end

  def to_a
    tags
  end

  def inspect
    "#<TagList #{tags.inspect}>"
  end

  def ==(other)
    other.is_a?(TagList) && tags == other.tags
  end

  def include?(tag)
    tags.include?(tag.to_s)
  end

  def size
    tags.size
  end
end

class TagListType < ActiveRecord::Type::Value
  def cast(value)
    case value
    when TagList then value
    when Array then TagList.new(value)
    when String then TagList.new(value.split(',').map(&:strip))
    when nil then TagList.new
    else TagList.new
    end
  end

  def serialize(value)
    case value
    when TagList then value.to_a.to_json
    when Array then value.to_json
    when nil then nil
    else value.to_json
    end
  end

  def deserialize(value)
    return TagList.new if value.nil?

    array = if value.is_a?(String)
              JSON.parse(value)
            else
              Array(value)
            end
    TagList.new(array)
  rescue JSON::ParserError
    TagList.new
  end
end



class MagicalCreature < ActiveRecord::Base
  validates_presence_of :name, :species
  serialize :powers, type: Array

  default_scope -> { where(deleted: false) }

  attribute :virtual, ActiveRecord::Type::Integer.new
  attribute :wizard_data, WizardDataType.new
  attribute :tag_list, TagListType.new
end

# Model with a real JSON column (not TEXT) to test JSONB serialization
class SimulationModel < ActiveRecord::Base
  attribute :configuration, WizardDataType.new
end

def create_and_blow_away_old_db
  ActiveRecord::Base.configurations = { 'test' => { 'adapter' => 'sqlite3', 'database' => 'test.db' } }

  ActiveRecord::Base.establish_connection(:test)

  ActiveRecord::Base.connection.create_table(:magical_creatures, force: true) do |t|
    t.column :name, :string
    t.column :species, :string
    t.column :powers, :string
    t.column :wizard_data, :text
    t.column :tag_list, :text
    t.column :deleted, :boolean, default: false, null: false
  end

  # Table with a real JSON column to test JSONB serialization
  ActiveRecord::Base.connection.create_table(:simulation_models, force: true) do |t|
    t.column :name, :string
    t.column :configuration, :json
  end
end

def force_fixture_generation
  FileUtils.rm(File.expand_path('../tmp/fixture_builder.yml', __dir__))
rescue StandardError
end

def force_fixture_generation_due_to_differing_file_hashes
  path = File.expand_path('../tmp/fixture_builder.yml', __dir__)
  File.write(path, 'blah blah blah')
rescue StandardError
end
