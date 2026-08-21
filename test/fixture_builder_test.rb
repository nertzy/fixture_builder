# frozen_string_literal: false

require File.expand_path(File.join(File.dirname(__FILE__), 'test_helper'))

class Model
  def self.table_name
    'models'
  end
end

class FixtureBuilderTest < Test::Unit::TestCase

  def teardown
    configuration = FixtureBuilder.instance_variable_get(:'@configuration')
    FileUtils.rm_f(configuration.fixture_builder_lock_file) if configuration
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

  def test_json_column_with_custom_type
    create_and_blow_away_old_db
    force_fixture_generation

    original_data = WizardData.new({ 'level' => 50, 'title' => 'Archmage', 'allies' => %w[Merlin Dumbledore] })

    FixtureBuilder.configure do |fbuilder|
      fbuilder.files_to_check += Dir[test_path('*.rb')]
      fbuilder.factory do
        @sim_model = SimulationModel.create!(
          name: 'Test Simulation',
          configuration: original_data
        )
      end
    end

    # Verify the fixture YAML contains a Hash (not a JSON string)
    generated_fixture = YAML.load(File.open(test_path('fixtures/simulation_models.yml')))
    config_value = generated_fixture['sim_model']['configuration']
    assert_instance_of Hash, config_value, "JSON column should serialize as Hash in YAML, not String"
    assert_equal 50, config_value['level']
    assert_equal 'Archmage', config_value['title']

    # Load fixtures and verify round-trip through ActiveRecord
    create_fixtures('simulation_models')
    sim_model = SimulationModel.find_by(name: 'Test Simulation')

    # Verify the custom object round-tripped correctly
    assert_instance_of WizardData, sim_model.configuration
    assert_equal original_data, sim_model.configuration

    # Verify the data is correct
    assert_equal 50, sim_model.configuration.level
    assert_equal 'Archmage', sim_model.configuration.title
    assert_equal %w[Merlin Dumbledore], sim_model.configuration.allies
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

  def test_rebuilds_when_generated_fixture_hashes_differ
    create_and_blow_away_old_db
    force_fixture_generation

    FixtureBuilder.configure do |fbuilder|
      fbuilder.files_to_check += Dir[test_path('*.rb')]
      fbuilder.factory do
        @enty = MagicalCreature.create(name: 'Enty', species: 'ent',
                                       powers: %w[shading rooting seeding])
      end
    end

    FixtureBuilder.instance_variable_set(:'@configuration', nil)
    fixture_path = test_path('fixtures/magical_creatures.yml')
    generated_fixture = YAML.load_file(fixture_path)
    generated_fixture['enty']['retired_column'] = 'bogus'
    File.write(fixture_path, generated_fixture.to_yaml)

    FixtureBuilder.configure do |fbuilder|
      fbuilder.files_to_check += Dir[test_path('*.rb')]
      fbuilder.factory do
        @enty = MagicalCreature.create(name: 'Enty', species: 'ent',
                                       powers: %w[shading rooting seeding])
      end
    end

    regenerated_fixture = YAML.load_file(fixture_path)
    assert_false regenerated_fixture['enty'].key?('retired_column')
    assert_equal 'Enty', regenerated_fixture['enty']['name']
    assert_equal 'ent', regenerated_fixture['enty']['species']

    create_fixtures('magical_creatures')
    loaded = MagicalCreature.find_by!(name: 'Enty')
    assert_equal %w[shading rooting seeding], loaded.powers
  end

  def test_rebuilds_legacy_manifest_once_and_upgrades_it
    create_and_blow_away_old_db
    force_fixture_generation
    builds = 0

    FixtureBuilder.configure do |fbuilder|
      fbuilder.files_to_check += Dir[test_path('*.rb')]
      fbuilder.factory do
        builds += 1
        @enty = MagicalCreature.create(name: 'Enty', species: 'ent')
      end
    end

    manifest_path = File.expand_path('../tmp/fixture_builder.yml', __dir__)
    legacy_sources = YAML.load_file(manifest_path).fetch('sources')
    File.write(manifest_path, legacy_sources.to_yaml)
    FixtureBuilder.instance_variable_set(:'@configuration', nil)

    FixtureBuilder.configure do |fbuilder|
      fbuilder.files_to_check += Dir[test_path('*.rb')]
      fbuilder.factory do
        builds += 1
        @enty = MagicalCreature.create(name: 'Enty', species: 'ent')
      end
    end

    upgraded_manifest = YAML.load_file(manifest_path)
    assert_equal 2, upgraded_manifest['version']
    assert_equal legacy_sources, upgraded_manifest['sources']
    assert_equal %w[magical_creatures.yml simulation_models.yml], upgraded_manifest['fixtures'].keys

    FixtureBuilder.instance_variable_set(:'@configuration', nil)
    FixtureBuilder.configure do |fbuilder|
      fbuilder.files_to_check += Dir[test_path('*.rb')]
      fbuilder.factory do
        builds += 1
        @enty = MagicalCreature.create(name: 'Enty', species: 'ent')
      end
    end
    assert_equal 2, builds
  end

  def test_rebuilds_when_manifest_is_empty
    assert_manifest_rebuilds('')
  end

  def test_rebuilds_when_manifest_is_false
    assert_manifest_rebuilds("false\n")
  end

  def test_rebuilds_when_manifest_is_scalar
    assert_manifest_rebuilds("scalar\n")
  end

  def test_rebuilds_when_current_manifest_shape_is_invalid
    invalid_current = <<~YAML
      ---
      version: 2
      sources: {}
      fixtures: {}
      1: invalid
    YAML

    assert_manifest_rebuilds(invalid_current)
  end

  def test_malformed_manifest_raises_without_running_factory
    create_and_blow_away_old_db
    manifest_path = File.expand_path('../tmp/fixture_builder.yml', __dir__)
    File.write(manifest_path, "---\ninvalid: [\n")
    factory_called = false

    assert_raise(Psych::SyntaxError) do
      FixtureBuilder.configure do |fbuilder|
        fbuilder.files_to_check += Dir[test_path('*.rb')]
        fbuilder.factory { factory_called = true }
      end
    end

    assert_false factory_called
  end

  def test_rebuilds_when_manifest_disappears_during_preflight
    create_and_blow_away_old_db
    force_fixture_generation
    builds = 0
    factory = proc do
      builds += 1
      @enty = MagicalCreature.create(name: 'Enty', species: 'ent')
    end

    FixtureBuilder.configure do |fbuilder|
      fbuilder.files_to_check += Dir[test_path('*.rb')]
      fbuilder.factory(&factory)
    end
    FixtureBuilder.instance_variable_set(:'@configuration', nil)

    FixtureBuilder.configure do |fbuilder|
      fbuilder.files_to_check += Dir[test_path('*.rb')]
      remove_manifest_before_read = Module.new do
        define_method(:read_config) do
          FileUtils.rm(fixture_builder_file)
          super()
        end
      end
      fbuilder.singleton_class.prepend(remove_manifest_before_read)
      fbuilder.factory(&factory)
    end

    assert_equal 2, builds
  end


  def test_fixture_builder_lock_file_uses_expanded_manifest_path
    configuration = FixtureBuilder::Configuration.new
    configuration.fixture_builder_file = Pathname.new('tmp/custom-fixture-builder.yml')
    expected = "#{File.expand_path(configuration.fixture_builder_file)}.lock"
    original_test_env_number = ENV.fetch('TEST_ENV_NUMBER', nil)
    original_parallel_workers = ENV.fetch('PARALLEL_WORKERS', nil)

    assert_equal expected, configuration.fixture_builder_lock_file
    ENV['TEST_ENV_NUMBER'] = '7'
    ENV['PARALLEL_WORKERS'] = '12'
    assert_equal expected, configuration.fixture_builder_lock_file
  ensure
    ENV['TEST_ENV_NUMBER'] = original_test_env_number
    ENV['PARALLEL_WORKERS'] = original_parallel_workers
  end

  def test_fresh_manifest_returns_without_acquiring_lock
    create_and_blow_away_old_db
    force_fixture_generation
    builds = 0
    lock_path = nil

    FixtureBuilder.configure do |fbuilder|
      fbuilder.files_to_check += Dir[test_path('*.rb')]
      lock_path = fbuilder.fixture_builder_lock_file
      fbuilder.factory do
        builds += 1
        @enty = MagicalCreature.create(name: 'Enty', species: 'ent')
      end
    end

    assert_path_exist lock_path
    FileUtils.rm(lock_path)
    FixtureBuilder.instance_variable_set(:'@configuration', nil)

    FixtureBuilder.configure do |fbuilder|
      fbuilder.files_to_check += Dir[test_path('*.rb')]
      fbuilder.factory { builds += 1 }
    end

    assert_equal 1, builds
    assert_path_not_exist lock_path
  end

  def test_skips_rebuild_for_valid_empty_fixture_snapshot
    create_and_blow_away_old_db
    force_fixture_generation
    fixture_snapshot = Dir[test_path('fixtures/*.yml')].to_h do |filename|
      [filename, File.binread(filename)]
    end
    FileUtils.rm_f(Dir[test_path('fixtures/*.yml')])
    builds = 0

    FixtureBuilder.configure do |fbuilder|
      fbuilder.files_to_check += Dir[test_path('*.rb')]
      fbuilder.write_empty_files = false
      fbuilder.factory { builds += 1 }
    end

    manifest_path = File.expand_path('../tmp/fixture_builder.yml', __dir__)
    assert_empty YAML.safe_load_file(manifest_path).fetch('fixtures')
    FixtureBuilder.instance_variable_set(:'@configuration', nil)

    FixtureBuilder.configure do |fbuilder|
      fbuilder.files_to_check += Dir[test_path('*.rb')]
      fbuilder.write_empty_files = false
      fbuilder.factory { builds += 1 }
    end

    assert_equal 1, builds
  ensure
    current_fixtures = Dir[test_path('fixtures/*.yml')]
    FileUtils.rm_f(current_fixtures - fixture_snapshot.keys) if fixture_snapshot
    fixture_snapshot&.each { |filename, contents| File.binwrite(filename, contents) }
  end

  def test_raising_after_build_invalidates_manifest_and_retries
    create_and_blow_away_old_db
    force_fixture_generation
    builds = 0
    factory = proc do
      builds += 1
      @enty = MagicalCreature.create(name: 'Enty', species: 'ent')
    end

    FixtureBuilder.configure do |fbuilder|
      fbuilder.files_to_check += Dir[test_path('*.rb')]
      fbuilder.factory(&factory)
    end

    manifest_path = Rails.root.join('tmp', 'fixture_builder.yml')
    fixture_path = test_path('fixtures/magical_creatures.yml')
    manifest_before = YAML.safe_load_file(manifest_path)
    generated_fixture = YAML.safe_load_file(fixture_path)
    generated_fixture['enty']['retired_column'] = 'bogus'
    File.write(fixture_path, generated_fixture.to_yaml)
    create_and_blow_away_old_db
    FixtureBuilder.instance_variable_set(:'@configuration', nil)

    error = assert_raise(RuntimeError) do
      FixtureBuilder.configure do |fbuilder|
        fbuilder.files_to_check += Dir[test_path('*.rb')]
        fbuilder.after_build = proc { raise 'after build failure' }
        fbuilder.factory(&factory)
      end
    end

    assert_equal 'after build failure', error.message
    expected_hash = manifest_before.fetch('fixtures').fetch(File.basename(fixture_path))
    assert_equal expected_hash, Digest::MD5.file(fixture_path).hexdigest
    assert_false File.exist?(manifest_path)

    FixtureBuilder.instance_variable_set(:'@configuration', nil)
    FixtureBuilder.configure do |fbuilder|
      fbuilder.files_to_check += Dir[test_path('*.rb')]
      fbuilder.factory(&factory)
    end

    manifest_after = YAML.safe_load_file(manifest_path)
    assert_equal 3, builds
    assert_equal 2, manifest_after['version']
    assert_equal Digest::MD5.file(fixture_path).hexdigest,
                 manifest_after.fetch('fixtures').fetch(File.basename(fixture_path))
  end

  def test_sha1_digests
    create_and_blow_away_old_db
    force_fixture_generation_due_to_differing_file_hashes

    source_path = Pathname.new(test_path('fixture_builder_test.rb'))
    FixtureBuilder.configure(use_sha1_digests: true) do |fbuilder|
      fbuilder.files_to_check = [source_path]
      fbuilder.factory do
        @enty = MagicalCreature.create(name: 'Enty', species: 'ent',
                                       powers: %w[shading rooting seeding])
      end
      manifest = YAML.safe_load_file(File.expand_path('../tmp/fixture_builder.yml', __dir__))
      fixture_path = test_path('fixtures/magical_creatures.yml')
      assert_equal Digest::SHA1.file(source_path).hexdigest,
                   manifest.fetch('sources').fetch(source_path.to_s)
      assert_equal Digest::SHA1.file(fixture_path).hexdigest,
                   manifest.fetch('fixtures').fetch(File.basename(fixture_path))

      first_modified_time = File.mtime(fixture_path)
      fbuilder.factory do
      end
      second_modified_time = File.mtime(test_path('fixtures/magical_creatures.yml'))
      assert_equal first_modified_time, second_modified_time
    end
  end

  private

  def assert_manifest_rebuilds(payload)
    create_and_blow_away_old_db
    force_fixture_generation
    builds = 0
    factory = proc do
      builds += 1
      @enty = MagicalCreature.create(name: 'Enty', species: 'ent')
    end

    FixtureBuilder.configure do |fbuilder|
      fbuilder.files_to_check += Dir[test_path('*.rb')]
      fbuilder.factory(&factory)
    end

    manifest_path = File.expand_path('../tmp/fixture_builder.yml', __dir__)
    File.write(manifest_path, payload)
    FixtureBuilder.instance_variable_set(:'@configuration', nil)
    FixtureBuilder.configure do |fbuilder|
      fbuilder.files_to_check += Dir[test_path('*.rb')]
      fbuilder.factory(&factory)
    end

    assert_equal 2, builds
  end


end
