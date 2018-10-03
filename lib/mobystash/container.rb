require 'logstash_writer'
require 'murmurhash3'

require 'mobystash/moby_event_worker'

module Mobystash
  # Hoovers up logs for a single container and passes them on to the writer.
  class Container
    include Mobystash::MobyEventWorker

    # docker_data is the Docker::Container instance representing the moby
    # container metadata, and system_config is the Mobystash::Config.
    #
    def initialize(docker_data, system_config)
      @id = docker_data.id

      @config = system_config
      @logger = @config.logger
      @writer = @config.logstash_writer

      @name = (docker_data.info["Name"] || docker_data.info["Names"].first).sub(/\A\//, '')

      @capture_logs = true
      @tags = {
        "moby.name"     => @name,
        "moby.id"       => @id,
        "moby.hostname" => docker_data.info["Config"]["Hostname"],
        "moby.image"    => docker_data.info["Config"]["Image"],
        "moby.image_id" => docker_data.info["Image"],
      }

      @last_log_timestamp = Time.at(0)

      parse_labels(docker_data.info["Config"]["Labels"])

      super
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
      @config.read_event_exception_counter.increment(container_name: @name, container_id: @id, class: ex.class.to_s)
    end

    def short_id
      @id[0..11]
    end

    def parse_labels(labels)
      labels.each do |lbl, val|
        case lbl
        when "org.discourse.mobystash.disable"
          @capture_logs = !!(val =~ /\Ayes|1|on|true\z/i)
        when "org.discourse.mobystash.filter_regex"
          @filter_regex = Regexp.new(val)
        when /\Aorg\.discourse\.mobystash\.tag\.(.*)\z/
          @tags[$1] = val
        end
      end
    end

    def process_events(conn)
      if @capture_logs
        @logger.debug(progname) { "Capturing logs since #{@last_log_timestamp.strftime("%FT%T.%NZ")}" }

        c = Docker::Container.get(@id, {}, conn)
        c.streaming_logs(since: @last_log_timestamp.strftime("%s.%N"), timestamps: true, follow: true, stdout: true, stderr: true, tty: c.info["Config"]["Tty"]) do |s, msg|
          # Le sigh... normally, the first argument is the stream and the
          # second is the message, but if we're running a TTY, the first argument is actually
          # the message and the second argument is nil.  WHYYYYYYYYYYY?!??!
          if msg.nil?
            msg = s
            s = :tty
          end

          send_event(msg, s)
        end
      else
        @logger.debug(progname) { "Not capturing logs because mobystash is disabled" }
        sleep
      end
    end

    def send_event(msg, stream)
      @config.log_entries_read_counter.increment(container_name: @name, container_id: @id, stream: stream)

      ts, msg = msg.chomp.split(' ', 2)
      @last_log_timestamp = Time.strptime(ts, "%FT%T.%N%Z")
      unless @filter_regex && @filter_regex =~ msg
        event = @tags.merge("moby.stream" => stream.to_s, "@timestamp" => ts, "message" => msg)
        event["_id"] = MurmurHash3::V128.murmur3_128_str_base64digest(event.to_json)[0..-3]
        @config.logstash_writer.send_event(event)
        @config.log_entries_sent_counter.increment(container_name: @name, container_id: @id, stream: stream)
      end
    end
  end
end
