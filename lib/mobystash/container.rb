# frozen_string_literal: true
require 'deep_merge'
require 'murmurhash3'

TIMESTAMP_FORMAT = '%FT%T.%3NZ'


# Hoovers up logs for a single container and passes them on to the writer.
class Mobystash::Container
  include Mobystash::MobyEventWorker

  # This is needed because floats are terribad at this level of precision,
  # and it works because Time happens to be based on Rational.
  #
  ONE_NANOSECOND = Rational('1/1000000000')
  private_constant :ONE_NANOSECOND

  SYSLOG_FACILITIES = %w{
      kern
      user
      mail
      daemon
      auth
      syslog
      lpr
      news
      uucp
      cron
      authpriv
      ftp
      reserved12 reserved13 reserved14 reserved15
      local0 local1 local2 local3 local4 local5 local6 local7
  }

  SYSLOG_SEVERITIES = %w{
      emerg
      alert
      crit
      err
      warning
      notice
      info
      debug
  }

  private_constant :SYSLOG_FACILITIES, :SYSLOG_SEVERITIES

  # docker_data is the Docker::Container instance representing the moby
  # container metadata, and system_config is the Mobystash::Config.
  #
  def initialize(docker_data, system_config, last_log_time:, sampler:, metrics:)
    @id = docker_data.id

    @config  = system_config
    @logger  = @config.logger
    @writer  = @config.writer
    @sampler = sampler
    @metrics = metrics

    @name = (docker_data.info["Name"] || docker_data.info["Names"].first).sub(/\A\//, '')

    @capture_logs = true
    @parse_syslog = false

    @tags = {
      ecs: {
        version: '1.8'
      },
      container: {
        id: @id,
        image: {
          id: docker_data.info["Image"],
          name: docker_data.info["Config"]["Image"],
        },
        hostname: docker_data.info["Config"]["Hostname"],
        name: @name,
      }
    }

    @last_log_time = last_log_time || Time.at(0).utc
    @llt_mutex = Mutex.new

    parse_labels(docker_data.info["Config"]["Labels"])

    super

    if @capture_logs
      if docker_data.info["Config"]["Tty"]
        @metrics.log_entries_read_total.increment(labels: { container_name: @name, container_id: @id, stream: "tty" }, by: 0)
      else
        @metrics.log_entries_read_total.increment(labels: { container_name: @name, container_id: @id, stream: "stdout" }, by: 0)
        @metrics.log_entries_read_total.increment(labels: { container_name: @name, container_id: @id, stream: "stderr" }, by: 0)
      end
    end

    @logger.debug(progname) do
      (["Created new container listener.  Instance variables:"] + %i{@name @capture_logs @parse_syslog @tags @last_log_time}.map do |iv|
        "#{iv}=#{instance_variable_get(iv).inspect}"
      end).join("\n  ")
    end
  end

  # The RFC3339 format of the last log timestamp received.
  def last_log_timestamp
    @llt_mutex.synchronize { @last_log_time.strftime("%FT%T.%NZ") }
  end

  # The Time of the first possible time at which a new log message or event
  # could possibly have occurred, based on the timestamps of previous events
  # and/or log entries received from Moby.
  def next_log_time
    @llt_mutex.synchronize { @last_log_time + ONE_NANOSECOND }
  end

  def shutdown!
    @metrics.log_entries_read_total.remove(labels: { container_name: @name, container_id: @id, stream: "tty" })
    @metrics.log_entries_read_total.remove(labels: { container_name: @name, container_id: @id, stream: "stdout" })
    @metrics.log_entries_read_total.remove(labels: { container_name: @name, container_id: @id, stream: "stderr" })
    @metrics.log_entries_sent_total.remove(labels: { container_name: @name, container_id: @id, stream: "tty" })

    @metrics.log_entries_sent_total.remove(labels: { container_name: @name, container_id: @id, stream: "stdout" })
    @metrics.log_entries_sent_total.remove(labels: { container_name: @name, container_id: @id, stream: "stderr" })

    @metrics.last_log_entry_at.remove(labels: { container_name: @name, container_id: @id, stream: "stderr" })
    @metrics.last_log_entry_at.remove(labels: { container_name: @name, container_id: @id, stream: "stdout" })
    @metrics.last_log_entry_at.remove(labels: { container_name: @name, container_id: @id, stream: "tty" })

    @metrics.read_event_exceptions_total.to_h.each do |label, _|
      if (label[:container_id] == @id)
        @metrics.read_event_exceptions_total.remove(label)
      end
    end

    super
  end

  def parse_timestamp(t) # copied from syslogstash
    return Time.now.utc if t.nil?

    begin
      if t.start_with? '*'
        # unsynced timestamp from IOS, is useless
        Time.now.utc
      else
        # DateTime does a fairly sensible job of this
        DateTime.parse(t)
      end
    rescue
      # as good a fallback as any
      Time.now.utc
    end
  end

  private

  def progname
    @logger_progname ||= "Mobystash::Container(#{short_id})"
  end

  def docker_host
    @config.docker_host
  end

  def logger
    @logger
  end

  def event_exception(ex)
    @metrics.read_event_exceptions_total.increment(labels: { container_name: @name, container_id: @id, class: ex.class.to_s })
  end

  def short_id
    @id[0..11]
  end

  def parse_labels(labels)
    @logger.debug(progname) { "Parsing labels: #{labels.inspect}" }

    labels.each do |lbl, val|
      case lbl
      when "org.discourse.mobystash.disable"
        @logger.debug(progname) { "Found disable label, value: #{val.inspect}" }
        @capture_logs = !(val =~ /\Ayes|y|1|on|true|t\z/i)
        @logger.debug(progname) { "@capture_logs is now #{@capture_logs.inspect}" }
      when "org.discourse.mobystash.filter_regex"
        @logger.debug(progname) { "Found filter_regex label, value: #{val.inspect}" }
        @filter_regex = Regexp.new(val)
      when /\Aorg\.discourse\.mobystash\.tag\.(.*)\z/
        @logger.debug(progname) { "Found tag label #{$1}, value: #{val.inspect}" }
        @tags.deep_merge!(hashify_tag($1, val))
        @logger.debug(progname) { "Container tags is now #{@tags.inspect}" }
      when "org.discourse.mobystash.parse_syslog"
        @logger.debug(progname) { "Found parse_syslog label, value: #{val.inspect}" }
        @parse_syslog = !!(val =~ /\Ayes|y|1|on|true|t\z/i)
      end
    end
  end

  # Turn a dot-separated sequence of strings into a nested hash.
  #
  # @example
  #    hashify_tag("a.b.c", "42")
  #    => { a: { b: { c: "42" } } }
  #
  def hashify_tag(tag, val)
    if tag.index(".")
      tag, rest = tag.split(".", 2)
      { tag.to_sym => hashify_tag(rest, val) }
    else
      { tag.to_sym => val }
    end
  end

  def process_events(conn)
    begin
      if tty?(conn)
        @metrics.log_entries_sent_total.increment(labels: { container_name: @name, container_id: @id, stream: "tty" }, by: 0)
      else
        @metrics.log_entries_sent_total.increment(labels: { container_name: @name, container_id: @id, stream: "stdout" }, by: 0)
        @metrics.log_entries_sent_total.increment(labels: { container_name: @name, container_id: @id, stream: "stderr" }, by: 0)
      end

      if @capture_logs
        unless Docker::Container.get(@id, {}, conn).info.fetch("State", {})["Status"] == "running"
          @logger.debug(progname) { "Container is not running; waiting for it to start or be destroyed" }
          wait_for_container_to_start(conn)
        else
          @logger.debug(progname) { "Capturing logs from #{next_log_time}" }

          # The implementation of Docker::Container#streaming_logs has a
          # *terribad* memory leak, in that every log entry that gets received
          # gets stored in a couple of arrays, which only gets cleared when
          # the call to #streaming_logs finishes... which is bad, because
          # we like these to go on for a long time.  So, instead, we need to
          # do our own thing directly, by hand.
          chunk_parser = Mobystash::MobyChunkParser.new(tty: tty?(conn)) do |msg, s|
            send_event(msg, s)
          end

          conn.get(
            "/containers/#{@id}/logs",
            {
              since: next_log_time.strftime("%s.%N"),
              timestamps: true,
              follow: true,
              stdout: true,
              stderr: true,
            },
            idempotent: false,
            response_block: chunk_parser
          )
        end
      else
        @logger.debug(progname) { "Not capturing logs because mobystash is disabled" }
        sleep
      end
    rescue Docker::Error::NotFoundError, Docker::Error::ServerError
      # This happens when the container terminates, but we beat the System
      # in the race and we call Docker::Container.get before the System
      # shuts us down.  Since we'll be terminated soon anyway, we may as
      # well do it first.
      @logger.info(progname) { "Container has terminated." }
      raise TerminateEventWorker
    end
  end

  def wait_for_container_to_start(conn)
    @logger.debug(progname) { "Asking for events from #{next_log_time}" }

    Docker::Event.since(next_log_time.strftime("%s.%N"), {}, conn) do |event|
      @llt_mutex.synchronize { @last_log_time = Time.at(event.timeNano * ONE_NANOSECOND) }

      @logger.debug(progname) { "Docker event@#{event.timeNano}: #{event.Type}.#{event.Action} on #{event.ID}" }

      break if event.Type == "container" && event.ID == @id
    end
  end

  def send_event(msg, stream)
    @metrics.log_entries_read_total.increment(labels: { container_name: @name, container_id: @id, stream: stream.to_s })

    log_timestamp, msg = msg.chomp.split(' ', 2)
    log_time = Time.strptime(log_timestamp, "%FT%T.%N%Z")

    @llt_mutex.synchronize do
      @last_log_time = log_time
    end

    @metrics.last_log_entry_at.observe(
      log_time.to_f,
      labels: { container_name: @name, container_id: @id, stream: stream.to_s }
    )

    msg, syslog_fields = if @parse_syslog
                           parse_syslog(msg)
                         else
                           [msg, {}]
                         end

    passed, sampling_metadata = @sampler.sample(msg)

    return unless passed

    # match? is faster cause no globals are set
    if !@filter_regex || !msg.match?(@filter_regex)
      event = {
        message: msg,
        labels: {
          stream: stream.to_s,
        },
      }.deep_merge(syslog_fields).deep_merge(sampling_metadata).deep_merge!(@tags)
      if event.key? :"@timestamp"
        event.deep_merge({ event: { created: log_time.strftime("%FT%T.%NZ") } })
      else
        event[:"@timestamp"] = log_time.strftime("%FT%T.%NZ")
      end


      # Can't calculate the document_id until you've got a constructed event...
      metadata = {
        "@metadata": {
          document_id: MurmurHash3::V128.murmur3_128_str_base64digest(event.to_json)[0..-3],
          event_type: "moby",
        }
      }

      event = event.deep_merge(metadata)

      @writer.send_event(event)
      @metrics.log_entries_sent_total.increment(labels: { container_name: @name, container_id: @id, stream: stream.to_s })
    end
  end

  def parse_syslog(msg)
    if msg =~ /\A<(\d+)>(\w{3} [ 0-9]{2} [0-9:]{8}) (.*)\z/
      flags     = $1.to_i
      timestamp = $2
      content   = $3

      # Lo! the many ways that syslog messages can be formatted
      hostname, program, pid, message =
        case content
          # the gold standard: hostname, program name with optional PID
        when /^([a-zA-Z0-9._-]*[^:]) (\S+?)(\[(\d+)\])?: (.*)$/
          [$1, $2, $4, $5]
          # hostname, no program name
        when /^([a-zA-Z0-9._-]+) (\S+[^:] .*)$/
          [$1, nil, nil, $2]
          # program name, no hostname (yeah, you heard me, non-RFC compliant!)
        when /^(\S+?)(\[(\d+)\])?: (.*)$/
          [nil, $1, $3, $4]
        else
          # I have NFI
          [nil, nil, nil, content]
        end

      severity = flags % 8
      facility = flags / 8

      log = {
        '@timestamp': parse_timestamp(timestamp).strftime(TIMESTAMP_FORMAT),
        log: {
          original: msg,
          syslog: {
            severity: {
              code: severity,
              name: SYSLOG_SEVERITIES[severity],
            },
            facility: {
              code: facility,
              name: SYSLOG_FACILITIES[facility],
            },
          },
        }
      }
      log.deep_merge({ host: { hostname: hostname } }) unless hostname.nil?
      log.deep_merge({ process: { name: program } }) unless program.nil?
      log.deep_merge({ process: { pid: pid.to_i } }) unless pid.nil?

      [message, log]
    else
      [msg, {}]
    end
  end

  def tty?(conn)
    @tty ||= Docker::Container.get(@id, {}, conn).info["Config"]["Tty"]
  end
end
