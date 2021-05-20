require 'docker-api'

# Keep an eye on all events being emitted by the Moby server, and forward
# relevant ones to the main System by means of a message queue.
class Mobystash::MobyWatcher
  include Mobystash::MobyEventWorker

  # Set everything up.  `queue` is an instance of `Queue` that the `System`
  # instance is listening on, and `config` is the `Mobystash::Config`.
  def initialize(queue:, config:, metrics:)
    @queue, @config, @metrics = queue, config, metrics

    @docker_host = @config.docker_host
    @logger = @config.logger
    @last_event_time = Time.now.to_i

    @metrics.moby_events_total.increment(labels: { type: "ignored" }, by: 0)
    @metrics.moby_events_total.increment(labels: { type: "create"  }, by: 0)
    @metrics.moby_events_total.increment(labels: { type: "destroy" }, by: 0)

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
    @metrics.moby_watch_exceptions_total.increment(labels: { class: ex.class.to_s })
  end

  def process_events(conn)
    @logger.debug(progname) { "Asking for events since #{@last_event_time}" }

    Docker::Event.since(@last_event_time, {}, conn) do |event|
      @last_event_time = event.time

      @logger.debug(progname) { "Docker event@#{event.timeNano}: #{event.Type}.#{event.Action} on #{event.ID}" }

      next unless event.Type == "container"

      queue_item = if event.Action == "create"
                     @metrics.moby_events_total.increment(labels: { type: "create" })
                     [:created, event.ID]
                   elsif event.Action == "destroy"
                     @metrics.moby_events_total.increment(labels: { type: "destroy" })
                     [:destroyed, event.ID]
                   else
                     @metrics.moby_events_total.increment(labels: { type: "ignored" })
                     nil
                   end

      next if queue_item.nil? || queue_item.last.nil?

      @queue.push(queue_item)
    end
  end
end
