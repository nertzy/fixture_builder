# frozen_string_literal: false

require File.expand_path(File.join(File.dirname(__FILE__), 'test_helper'))

class Model
  def self.table_name
    'models'
  end
end

# Custom type that wraps JSON data in a rich Ruby object (like DataModel)
# This simulates the real-world scenario where a custom attribute type
# returns a complex object that would serialize with !ruby/object: YAML tags
class WizardData
  attr_accessor :level, :title, :allies

  def initialize(attrs = {})
    @level = attrs['level'] || attrs[:level]
    @title = attrs['title'] || attrs[:title]
    @allies = attrs['allies'] || attrs[:allies] || []
  end

  def to_h
    { 'level' => level, 'title' => title, 'allies' => allies }.compact
  end
end

class WizardDataType < ActiveRecord::Type::Value
  def type = :json

  def cast(value)
    case value
    when WizardData then value
    when Hash then WizardData.new(value)
    when String then WizardData.new(JSON.parse(value))
    when nil then nil
    else raise ArgumentError, "Cannot cast #{value.class} to WizardData"
    end
  end

  def serialize(value)
    return nil if value.nil?

    value.to_h.to_json
  end

  def deserialize(value)
    return nil if value.nil?

    data = value.is_a?(String) ? JSON.parse(value) : value
    WizardData.new(data)
  end
end

class FixtureBuilderTest < Test::Unit::TestCase
  def teardown
    FixtureBuilder.instance_variable_set(:'@configuration', nil)
  end

  def test_name_with
    hash = {
      'id' => 1,
      'email' => 'bob@example.com'
    }
    FixtureBuilder.configure do |config|
      config.name_model_with Model do |record_hash, index|
        [record_hash['email'].split('@').first, index].join('_')
      end
    end
    assert_equal 'bob_001', FixtureBuilder.configuration.send(:record_name, hash, Model.table_name, '000')
  end

  def test_ivar_naming
    create_and_blow_away_old_db
    force_fixture_generation

    FixtureBuilder.configure do |fbuilder|
      fbuilder.files_to_check += Dir[test_path('*.rb')]
      fbuilder.factory do
        @king_of_gnomes = MagicalCreature.create(name: 'robert', species: 'gnome')
      end
    end
    generated_fixture = YAML.load(File.open(test_path('fixtures/magical_creatures.yml')))
    assert_equal 'king_of_gnomes', generated_fixture.keys.first
  end

  def test_serialization
    create_and_blow_away_old_db
    force_fixture_generation

    FixtureBuilder.configure do |fbuilder|
      fbuilder.files_to_check += Dir[test_path('*.rb')]
      fbuilder.factory do
        @enty = MagicalCreature.create(name: 'Enty', species: 'ent',
                                       powers: %w[shading rooting seeding])
      end
    end
    generated_fixture = YAML.load(File.open(test_path('fixtures/magical_creatures.yml')))
    assert_equal "---\n- shading\n- rooting\n- seeding\n", generated_fixture['enty']['powers']
  end

  def test_do_not_include_virtual_attributes
    create_and_blow_away_old_db
    force_fixture_generation

    FixtureBuilder.configure do |fbuilder|
      fbuilder.files_to_check += Dir[test_path('*.rb')]
      fbuilder.factory do
        MagicalCreature.create(name: 'Uni', species: 'unicorn', powers: %w[rainbows flying])
      end
    end
    generated_fixture = YAML.load(File.open(test_path('fixtures/magical_creatures.yml')))
    assert !generated_fixture['uni'].key?('virtual')
  end

  def test_custom_json_type_does_not_serialize_as_ruby_object
    # This test covers the scenario where a custom ActiveRecord attribute type
    # wraps a JSONB column and returns a rich Ruby object (like DataModel).
    # Without the fix, the YAML would contain !ruby/object: tags which fail to load.
    create_and_blow_away_old_db

    # Add a wizard_data column to test custom type serialization
    ActiveRecord::Base.connection.add_column(:magical_creatures, :wizard_data, :text)

    # Extend the existing model with custom attribute type
    MagicalCreature.attribute :wizard_data, WizardDataType.new

    force_fixture_generation

    FixtureBuilder.configure do |fbuilder|
      fbuilder.files_to_check += Dir[test_path('*.rb')]
      fbuilder.factory do
        @gandalf = MagicalCreature.create!(
          name: 'Gandalf',
          species: 'wizard',
          wizard_data: { 'level' => 99, 'title' => 'The Grey', 'allies' => %w[Frodo Aragorn] }
        )
      end
    end

    # Read the raw YAML to check for !ruby/object: tags
    yaml_content = File.read(test_path('fixtures/magical_creatures.yml'))

    # The YAML should NOT contain !ruby/object: tags
    refute_match(/!ruby\/object:/, yaml_content,
                 "YAML should not contain !ruby/object: tags. Got:\n#{yaml_content}")

    # The data should be loadable as a plain Hash
    generated_fixture = YAML.load_file(test_path('fixtures/magical_creatures.yml'))
    wizard_data = generated_fixture['gandalf']['wizard_data']

    assert_kind_of Hash, wizard_data,
                   "Expected wizard_data to be Hash but was #{wizard_data.class}: #{wizard_data.inspect}"
    assert_equal 99, wizard_data['level']
    assert_equal 'The Grey', wizard_data['title']
    assert_equal %w[Frodo Aragorn], wizard_data['allies']
  end

  def test_configure
    FixtureBuilder.configure do |config|
      assert config.is_a?(FixtureBuilder::Configuration)
      @called = true
    end
    assert @called
  end

  def test_absolute_rails_fixtures_path
    assert_equal File.expand_path('../test/fixtures', __dir__),
                 FixtureBuilder::FixturesPath.absolute_rails_fixtures_path
  end

  def test_fixtures_dir
    assert_match(%r{test/fixtures$}, FixtureBuilder.configuration.send(:fixtures_dir).to_s)
  end

  def test_rebuilding_due_to_differing_file_hashes
    create_and_blow_away_old_db
    force_fixture_generation_due_to_differing_file_hashes

    FixtureBuilder.configure do |fbuilder|
      fbuilder.files_to_check += Dir[test_path('*.rb')]
      fbuilder.factory do
        @enty = MagicalCreature.create(name: 'Enty', species: 'ent',
                                       powers: %w[shading rooting seeding])
      end
    end
    generated_fixture = YAML.load(File.open(test_path('fixtures/magical_creatures.yml')))
    assert_equal "---\n- shading\n- rooting\n- seeding\n", generated_fixture['enty']['powers']
  end

  def test_sha1_digests
    create_and_blow_away_old_db
    force_fixture_generation_due_to_differing_file_hashes

    FixtureBuilder.configure(use_sha1_digests: true) do |fbuilder|
      fbuilder.files_to_check += Dir[test_path('*.rb')]
      fbuilder.factory do
        @enty = MagicalCreature.create(name: 'Enty', species: 'ent',
                                       powers: %w[shading rooting seeding])
      end
      first_modified_time = File.mtime(test_path('fixtures/magical_creatures.yml'))
      fbuilder.factory do
      end
      second_modified_time = File.mtime(test_path('fixtures/magical_creatures.yml'))
      assert_equal first_modified_time, second_modified_time
    end
  end
end
