require 'loggerstash'
require 'logstash_writer'

require 'service_skeleton'

class Mobystash
  include ServiceSkeleton

  boolean   :MOBYSTASH_ENABLE_METRICS, default: false
  integer   :MOBYSTASH_METRICS_PORT, default: 9367
  float     :MOBYSTASH_SAMPLE_RATIO, default: 1, range: 1..Float::INFINITY
  float     :MOBYSTASH_STATE_CHECKPOINT_INTERVAL, default: 1, range: 0..Float::INFINITY
  kv_list   :MOBYSTASH_SAMPLE_KEYS, default: {}, key_pattern: /\AMOBYSTASH_SAMPLE_KEY_(.*)\z/
  string    :MOBYSTASH_STATE_FILE, default: "./mobystash_state.dump"
  string    :DOCKER_HOST, default: "unix:///var/run/docker.sock"

  counter :mobystash_moby_read_event_exceptions_total,
          docstring: " Exception counts while attempting to read log entries from the Moby server",
          labels: [:container_name, :container_id, :class]

  counter :mobystash_log_entries_read_total,
          docstring: "How many log entries have been received from Moby",
          labels: [:container_name, :container_id, :stream]

  counter :mobystash_log_entries_sent_total,
          docstring: "How many log entries have been sent to the LogstashWriter",
          labels: [:container_name, :container_id, :stream]

  counter :mobystash_sampled_entries_sent_total,
          docstring: "The number of sampled entries which have been sent",
          labels: [:sample_key]

  counter :mobystash_sampled_entries_dropped_total,
          docstring: "The number of sampled log entries which didn't get sent",
          labels: [:sample_key]

  counter :mobystash_unsampled_entries_total,
          docstring: "How many log messages we've seen which didn't match any defined sample keys"

  counter :mobystash_moby_watch_exceptions_total,
          docstring: "How many exceptions have been raised while handling docker events",
          labels: [:class]

  counter :mobystash_moby_events_total,
          docstring: "How many docker events we have seen and processed",
          labels: [:type]

  histogram :mobystash_last_log_entry_at,
            docstring: "The time at which the last log entry was timestamped",
            labels: [:container_name, :container_id, :stream]

  gauge :mobystash_sample_ratios,
        docstring: "The current sample ratio for each sample key",
        labels: [:sample_key]

  def initialize(*_)
    super

    writer = LogstashWriter.new(server_name: config.logstash_server, backlog: config.backlog_size, logger: logger, metrics_registry: metrics, metrics_prefix: :syslogstash_writer)
    sampler = MobyStash::Sampler.new(config, metrics)
    @system = Mobystash::System.new(config, logger: logger, metrics: metrics, writer: writer, sampler: sampler)
  end

  def run
    @system.start!
  end
end

require_relative "mobystash/log_exception"
require_relative "mobystash/moby_chunk_parser"
require_relative "mobystash/moby_event_worker"
require_relative "mobystash/container"
require_relative "mobystash/moby_watcher"
require_relative "mobystash/sampler"
require_relative "mobystash/system"
