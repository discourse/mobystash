require 'docker-api'

module Mobystash
  # Keep an eye on all events being emitted by the Moby server, and forward
  # relevant ones to the main System by means of a message queue.
  class MobyWatcher
    include MobyEventWorker

    # Set everything up.  `queue` is an instance of `Queue` that the `System`
    # instance is listening on, and `config` is the `Mobystash::Config`.
    def initialize(queue:, config:)
      @queue, @config = queue, config

      @docker_host = @config.docker_host
      @logger = @config.logger
      @last_event_time = Time.now.to_i

      @event_count = @config.add_counter(
        "mobystash_moby_events_total",
        "How many docker events we have seen and processed"
      )

      @event_count.increment({ type: "ignored" }, 0)
      @event_count.increment({ type: "create"  }, 0)
      @event_count.increment({ type: "destroy" }, 0)

      @event_errors = @config.add_counter(
        "mobystash_moby_watch_exceptions_total",
        "How many exceptions have been raised while handling docker events"
      )

      super
    end

    private

    def progname
      @logger_progname ||= "Mobystash::MobyWatcher(#{@docker_host.inspect})"
    end

    def logger
      @logger
    end

    def docker_host
      @docker_host
    end

    def event_exception(ex)
      @event_errors.increment(class: ex.class.to_s)
    end

    def process_events(conn)
      @logger.debug(progname) { "Asking for events since #{@last_event_time}" }

      Docker::Event.since(@last_event_time, {}, conn) do |event|
        @last_event_time = event.time

        @logger.debug(progname) { "Docker event@#{event.timeNano}: #{event.Type}.#{event.Action} on #{event.ID}" }

        next unless event.Type == "container"

        queue_item = if event.Action == "create"
          @event_count.increment(type: "create")
          [:created, event.ID]
        elsif event.Action == "destroy"
          @event_count.increment(type: "destroy")
          [:destroyed, event.ID]
        else
          @event_count.increment(type: "ignored")
          nil
        end

        next if queue_item.nil? || queue_item.last.nil?

        @queue.push(queue_item)
      end
    end
  end
end
