# frozen_string_literal: false

require File.expand_path(File.join(File.dirname(__FILE__), 'test_helper'))

class Model
  def self.table_name
    'models'
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

    # Test round-trip through fixture loading
    create_fixtures('magical_creatures')
    loaded = MagicalCreature.find_by(name: 'Enty')
    assert_equal %w[shading rooting seeding], loaded.powers
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

  def test_json_backed_custom_type
    create_and_blow_away_old_db
    force_fixture_generation

    original_data = WizardData.new({ 'level' => 99, 'title' => 'The Grey', 'allies' => %w[Frodo Aragorn] })

    FixtureBuilder.configure do |fbuilder|
      fbuilder.files_to_check += Dir[test_path('*.rb')]
      fbuilder.factory do
        @gandalf = MagicalCreature.create!(
          name: 'Gandalf',
          species: 'wizard',
          wizard_data: original_data
        )
      end
    end

    # Load fixtures and verify round-trip through ActiveRecord
    create_fixtures('magical_creatures')
    gandalf = MagicalCreature.find_by(name: 'Gandalf')

    # Verify the custom object round-tripped correctly
    assert_instance_of WizardData, gandalf.wizard_data
    assert_equal original_data, gandalf.wizard_data
    assert_equal original_data.inspect, gandalf.wizard_data.inspect

    # Verify the data is correct
    assert_equal 99, gandalf.wizard_data.level
    assert_equal 'The Grey', gandalf.wizard_data.title
    assert_equal %w[Frodo Aragorn], gandalf.wizard_data.allies
  end

  def test_array_backed_custom_type
    create_and_blow_away_old_db
    force_fixture_generation

    original_tags = TagList.new(%w[magic fantasy enchanted ancient])

    FixtureBuilder.configure do |fbuilder|
      fbuilder.files_to_check += Dir[test_path('*.rb')]
      fbuilder.factory do
        @merlin = MagicalCreature.create!(
          name: 'Merlin',
          species: 'wizard',
          tag_list: original_tags
        )
      end
    end

    # Load fixtures and verify round-trip through ActiveRecord
    create_fixtures('magical_creatures')
    merlin = MagicalCreature.find_by(name: 'Merlin')

    # Verify the custom object round-tripped correctly
    assert_instance_of TagList, merlin.tag_list
    assert_equal original_tags, merlin.tag_list
    assert_equal original_tags.inspect, merlin.tag_list.inspect

    # Verify the data is correct (TagList normalizes by sorting)
    assert_equal %w[ancient enchanted fantasy magic], merlin.tag_list.to_a
    assert_equal 4, merlin.tag_list.size
    assert merlin.tag_list.include?('magic')
    assert merlin.tag_list.include?('ancient')
    refute merlin.tag_list.include?('modern')
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

    # Test round-trip through fixture loading
    create_fixtures('magical_creatures')
    loaded = MagicalCreature.find_by(name: 'Enty')
    assert_equal %w[shading rooting seeding], loaded.powers
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
