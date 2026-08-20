# frozen_string_literal: true

require 'bundler/setup'
require 'active_support'
require 'fileutils'
require 'fixture_builder'

$stdout.sync = true

root, role, scenario = ARGV
source_path = File.join(root, 'source.rb')
fixture_directory = File.join(root, 'fixtures')
fixture_path = File.join(fixture_directory, 'records.yml')
manifest_path = File.join(root, 'state', 'fixture_builder.yml')
marker_path = File.join(root, 'builds.log')
preflight_path = File.join(root, 'preflight.log')
release_path = File.join(root, 'release.log')

class FixtureBuilder::Builder
  def generate!
    @builder_block.call
    @configuration.after_build&.call
    self
  end
end

def append_line(path, line)
  File.open(path, File::RDWR | File::CREAT | File::APPEND) do |file|
    file.flock(File::LOCK_EX)
    first_line = file.size.zero?
    file.puts(line)
    file.flush
    file.fsync
    first_line
  end
end

def wait_for_lines(path, count)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
  until File.exist?(path) && File.readlines(path).length >= count
    raise "timed out waiting for #{count} lines in #{path}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

    sleep 0.01
  end
end

configuration = FixtureBuilder::Configuration.new
configuration.files_to_check = [source_path]
configuration.fixture_directory = fixture_directory
configuration.fixture_builder_file = manifest_path

if scenario == 'source_change'
  barrier = Module.new do
    define_method(:rebuild_fixtures?) do |*args, **kwargs|
      result = kwargs.empty? ? super(*args) : super(*args, **kwargs)
      unless @preflight_barrier_complete
        @preflight_barrier_complete = true
        append_line(preflight_path, role)
        wait_for_lines(preflight_path, 2)
      end
      result
    end
  end
  configuration.singleton_class.prepend(barrier)
elsif scenario == 'failing'
  configuration.after_build = proc do
    wait_for_lines(release_path, 1)
    raise 'after build failure'
  end
end

configuration.factory do
  first_build = append_line(marker_path, "#{role}:#{Process.pid}")
  File.write(source_path, "changed by #{role}\n") if scenario == 'source_change' && first_build
  wait_for_lines(release_path, 1) if scenario == 'holding'
  File.write(fixture_path, "#{role}:#{Process.pid}\n")
end
