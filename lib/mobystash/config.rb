require 'logger'
require 'logstash_writer'
require 'prometheus/client'
require 'mobystash/sampler'

module Mobystash
  # Encapsulates all common configuration parameters and shared metrics.
  class Config
    # Raised if any problems were found with the config
    class InvalidEnvironmentError < StandardError; end

    attr_reader :logstash_writer,
                :enable_metrics,
                :sample_ratio,
                :sample_keys,
                :sampler,
                :state_file,
                :state_checkpoint_interval,
                :docker_host

    attr_reader :logger

    attr_reader :metrics_registry

    attr_reader :read_event_exception_counter,
                :log_entries_read_counter,
                :log_entries_sent_counter,
                :last_log_entry_at,
                :sampled_entries_sent,
                :sampled_entries_dropped,
                :unsampled_entries,
                :sample_ratios

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
      @sampler = Mobystash::Sampler.new(self)

      parse_env(env)

      @read_event_exception_counter = @metrics_registry.counter(:mobystash_moby_read_exceptions_total, "Exception counts while attempting to read log entries from the Moby server")
      @log_entries_read_counter     = @metrics_registry.counter(:mobystash_log_entries_read_total, "How many log entries have been received from Moby")
      @log_entries_sent_counter     = @metrics_registry.counter(:mobystash_log_entries_sent_total, "How many log entries have been sent to the LogstashWriter")
      @last_log_entry_at            = @metrics_registry.gauge(:mobystash_last_log_entry_at_seconds, "The time at which the last log entry was timestamped")
      @sampled_entries_sent         = @metrics_registry.counter(:mobystash_sampled_entries_sent_total, "The number of sampled entries which have been sent")
      @sampled_entries_dropped      = @metrics_registry.counter(:mobystash_sampled_entries_dropped_total, "The number of sampled log entries which didn't get sent")
      @unsampled_entries            = @metrics_registry.counter(:mobystash_unsampled_entries_total, "How many log messages we've seen which didn't match any defined sample keys")
      @sample_ratios                = @metrics_registry.gauge(:mobystash_sample_ratio, "The current sample ratio for each sample key")
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

      @enable_metrics            = pluck_boolean(env, "MOBYSTASH_ENABLE_METRICS", default: false)
      @sample_ratio              = pluck_float(env, "MOBYSTASH_SAMPLE_RATIO", default: 1, valid_range: 1..Float::INFINITY)
      @sample_keys               = pluck_sample_keys(env)
      @state_file                = pluck_string(env, "MOBYSTASH_STATE_FILE", default: "./mobystash_state.dump")
      @state_checkpoint_interval = pluck_float(env, "MOBYSTASH_STATE_CHECKPOINT_INTERVAL", default: 1, valid_range: 0..Float::INFINITY)
      @docker_host               = pluck_string(env, "DOCKER_HOST", default: "unix:///var/run/docker.sock")
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
          raise InvalidEnvironmentError, "Environment variable #{key} must be specified."
        else
          return default
        end
      end

      env[key]
    end

    def pluck_float(env, key, valid_range: nil, default: nil)
      if env[key].nil? || env[key].empty?
        return default
      end

      if env[key] !~ /\A-?\d+(?:\.\d*)?\z/
        raise InvalidEnvironmentError,
              "Value for #{key} (#{env[key].inspect}) is not a floating-point number"
      end

      v = env[key].to_f
      unless valid_range.nil? || valid_range.include?(v)
        raise InvalidEnvironmentError,
              "Value for #{key} (#{env[key]}) out of range (must be between #{valid_range.first} and #{valid_range.last} inclusive)"
      end

      v
    end

    def pluck_sample_keys(env)
      [].tap do |sample_keys|
        env.each do |k, v|
          if k =~ /\AMOBYSTASH_SAMPLE_KEY_(.*)\z/
            sample_keys << [Regexp.new(v), $1]
          end
        end
        # We really, *really* don't want pepole coming to rely on specific
        # ordering behaviour of sample keys, so on every run we shuffle the
        # key order so it'll break sooner rather than later.
      end.sort_by { rand }
    end
  end
end
