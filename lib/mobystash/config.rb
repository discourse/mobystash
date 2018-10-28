require 'logger'
require 'logstash_writer'
require 'prometheus/client'

module Mobystash
  # Encapsulates all common configuration parameters and shared metrics.
  class Config
    # Raised if any problems were found with the config
    class InvalidEnvironmentError < StandardError; end

    attr_reader :logstash_writer,
                :enable_metrics,
                :docker_host

    attr_reader :logger

    attr_reader :metrics_registry

    attr_reader :read_event_exception_counter,
                :log_entries_read_counter,
                :log_entries_sent_counter,
                :last_log_entry_at

    # Create a new Mobystash system config based on environment variables.
    #
    # Examines the environment passed in, and then creates a new system
    # object if all is well.
    #
    # @param env [Hash] the set of environment variables to use.
    #
    # @param logger [Logger] the logger to which all diagnostic and error
    #   data will be sent.
    #
    # @return [Mobystash::Config]
    #
    # @raise [InvalidEnvironmentError] if any problems are detected with the
    #   environment variables found.
    #
    def initialize(env, logger:)
      @logger = logger

      # Even if we're not actually *running* a metrics server, we still need
      # the registry in place, because conditionalising every metrics-related
      # operation on whether metrics are enabled is just... madness.
      @metrics_registry = Prometheus::Client::Registry.new

      parse_env(env)

      @read_event_exception_counter = @metrics_registry.counter(:mobystash_moby_read_exceptions_total, "Exception counts while attempting to read log entries from the Moby server")
      @log_entries_read_counter     = @metrics_registry.counter(:mobystash_log_entries_read_total, "How many log entries have been received from Moby")
      @log_entries_sent_counter     = @metrics_registry.counter(:mobystash_log_entries_sent_total, "How many log entries have been sent to the LogstashWriter")
      @last_log_entry_at            = @metrics_registry.gauge(:mobystash_last_log_entry_at_seconds, "The time at which the last log entry was timestamped")
    end

    private

    def parse_env(env)
      @logstash_writer = LogstashWriter.new(
        server_name: pluck_string(env, "LOGSTASH_SERVER"),
        logger: @logger,
        # We're shipping a lot of container logs, it seems reasonable to have
        # a larger-than-default buffer in case of accidents.
        backlog: 1_000_000,
        metrics_registry: @metrics_registry,
      )

      @enable_metrics  = pluck_boolean(env, "MOBYSTASH_ENABLE_METRICS", default: false)
      @docker_host     = pluck_string(env, "DOCKER_HOST", default: "unix:///var/run/docker.sock")
    end

    def pluck_boolean(env, key, default: nil)
      if env[key].nil? || env[key].empty?
        return default
      end

      case env[key]
      when /\A(no|off|0|false)\z/
        false
      when /\A(yes|on|1|true)\z/
        true
      else
        raise InvalidEnvironmentError,
          "Value for #{key} (#{env[key].inspect}) is not a valid boolean value"
      end
    end

    def pluck_string(env, key, default: nil)
      if env[key].nil? || env[key].empty?
        if default.nil?
          raise InvalidEnvironmentError, "Environment variable #{env} must be specified."
        else
          return default
        end
      end

      env[key]
    end
  end
end
