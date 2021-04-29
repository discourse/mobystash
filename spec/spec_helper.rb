require 'bundler'
Bundler.setup(:default, :development)
require 'rspec/core'
require 'rspec/mocks'

require 'simplecov'
require 'mobystash'

SimpleCov.start do
  add_filter('spec')
end

class MockConfig
  attr_accessor :drop_regex
  attr_reader :logger, :writer

  def initialize(logger, writer)
    @logger = logger
    @writer = writer
  end

  def syslog_socket
    '/somewhere/funny'
  end

  def relay_to_stdout
    false
  end

  def relay_sockets
    []
  end

  def enable_metrics
    true
  end

  def metrics
    []
  end

  def sample_ratio
    1
  end

  def sample_keys
    @sample_keys ||= {}
  end

  def docker_host
    "unix:///var/run/test.sock"
  end

  def state_file
    "./mobystash_state.dump"
  end

  def state_checkpoint_interval
    1
  end

  def add_fields
    @add_fields ||= {}
  end
end

class MockMetrics
  def moby_events_total
    @moby_events_total ||=
      Prometheus::Client::Counter.new(
        :moby_events_total,
        docstring: "How many docker events we have seen and processed",
        labels: [:type]
      )
  end

  def moby_watch_exceptions_total
    @mobystash_moby_watch_exceptions_total ||=
      Prometheus::Client::Counter.new(
        :mobystash_moby_watch_exceptions_total,
        docstring: "How many watch exceptions",
        labels: [:class]
      )
  end

  def log_entries_read_total
    @log_entries_read_total ||=
      Prometheus::Client::Counter.new(
        :log_entries_read_total,
        docstring: "something",
        labels: [:container_name, :container_id, :stream]
      )
  end

  def log_entries_sent_total
    @log_entries_sent_total ||=
      Prometheus::Client::Counter.new(
        :log_entries_sent_total,
        docstring: "something",
        labels: [:container_name, :container_id, :stream]
      )
  end

  def read_event_exceptions_total
    @read_event_exceptions_total ||=
      Prometheus::Client::Counter.new(
        :read_event_exceptions_total,
        docstring: "something",
        labels: [:container_name, :container_id, :class]
      )
  end

  def unsampled_entries_total
    @unsampled_entries_total ||=
      Prometheus::Client::Counter.new(
        :unsampled_entries_total,
        docstring: "something"
      )
  end

  def last_log_entry_at
    @last_log_entry_at ||=
      Prometheus::Client::Histogram.new(
        :last_log_entry_at,
        docstring: "something",
        labels: [:container_name, :container_id, :stream]
      )
  end

  def sample_ratios
    @sample_ratios ||=
      Prometheus::Client::Histogram.new(
        :sample_ratios,
        docstring: "something",
        labels: [:sample_key]
      )
  end
end

RSpec.configure do |config|
  # config.fail_fast = true
  config.full_backtrace = true
  config.order = :random

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end

require_relative './example_group_methods'
require_relative './example_methods'

RSpec.configure do |config|
  config.include ExampleMethods
  config.extend  ExampleGroupMethods
end
