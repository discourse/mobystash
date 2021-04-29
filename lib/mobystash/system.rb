# frozen_string_literal: true

require 'service_skeleton'

class Mobystash::System
  include ServiceSkeleton::LoggingHelpers
  attr_reader :config

  # Create a new mobystash system.
  #
  # @param config [Mobystash] service config
  #
  # @param logger [Logger] pass in a custom logger to the system.
  #
  # @param metrics [Prometheus::Client::Registry] pass in metrics registry to the system.
  #
  # @param writer [LogstashWriter] pass in logstash_writer to the system.
  #
  # @return [System]
  #
  def initialize(config, logger:, metrics:, writer:, sampler:)
    @config     = config
    @logger     = logger
    @queue      = Queue.new
    @metrics    = metrics
    @watcher    = Mobystash::MobyWatcher.new(queue: @queue, config: @config, metrics: @metrics)
    @sampler    = sampler
    @writer     = writer
    @containers = {}
  end

  # Start everything up!
  def start!
    Thread.current.name = progname

    @logger.info(progname) { "Starting Mobystash System" }

    @watcher.run!
    @config.writer.start!

    if @config.enable_metrics
      @logger.info(progname) { "Starting metrics server" }

      # TODO: Figure out what this should be
      #
      # @config.metrics.each do |metric|
        # @metrics_server.collector.register_metric(metric)
      # end

      # @metrics_server.start
    end

    run_existing_containers
    run_checkpoint_timer

    @logger.info(progname) { "Commencing real-time log collection" }

    loop do
      item = @queue.pop
      @logger.debug(progname) { "Received message #{item.inspect}" }

      case (item.first rescue nil)
      when :created
        begin
          unless @containers[item.last]
            @containers[item.last] = Mobystash::Container.new(Docker::Container.get(item.last, {}, docker_connection), @config, last_log_time: nil, sampler: @sampler, metrics: @metrics)
            @containers[item.last].run!
          end
        rescue Docker::Error::NotFoundError
          # This happens if the container goes away before we get around
          # to watching its logs; there's nothing we can do about this,
          # the container just never existed as far as we're concerned.
          @logger.debug(progname) { "Container #{item.last} disappeared before we could grab its logs" }
        end
      when :destroyed
        @containers.delete(item.last).tap { |c| c.shutdown! if c }
      when :checkpoint_state
        write_state_file
      when :terminate
        @logger.info(progname) { "Terminating." }
        if @checkpoint_timer_thread
          @checkpoint_timer_thread.kill
          @checkpoint_timer_thread.join rescue nil
          @checkpoint_timer_thread = nil
        end
        @watcher.shutdown!
        @containers.values.each { |c| c.shutdown! }
        write_state_file
        @config.writer.stop!

        # TODO: Figure that out too
        # if @metrics_server
          # PrometheusExporter::Instrumentation::Process.stop
          # @metrics_server.stop
        # end
        break
      else
        @logger.error(progname) { "SHOULDN'T HAPPEN: docker watcher sent an unrecognized message: #{item.inspect}.  This is a bug, please report it." }
      end
    end
  end

  # Tell the main worker loop to SHUT IT DOWN.
  def shutdown
    @logger.debug(progname) { "Received shutdown request" }

    @queue.push([:terminate])
  end

  # Force LogstashWriter to reconnect
  def reconnect!
    @config.writer.force_disconnect!
  end

  private

  def progname
    "Mobystash::System"
  end

  def run_existing_containers
    @logger.info(progname) { "Collecting logs for existing containers" }

    state_data = begin
                   Marshal.load(File.read(@config.state_file))
                 rescue Errno::ENOENT
                   @logger.info(progname) { "State file #{@config.state_file} does not exist; reading all log entries" }
                   {}
                 rescue TypeError
                   @logger.error(progname) { "State file #{@config.state_file} is corrupt; ignoring" }
                   {}
                 end

    # Docker's `.all` method returns wildly different data in each
    # container's `.info` structure to what `.get` returns (the API
    # endpoints have completely different schemas), and the `.all`
    # response is missing some things we rather want, so to get everything
    # we need, this individual enumeration is unfortunately necessary --
    # and, of course, because a container can cease to exist between when
    # we get the list and when we request it again, it all gets far more
    # complicated than it should need to be.
    #
    # Thanks, Docker!
    Docker::Container.all({}, docker_connection).each do |c|
      begin
        last_log_time = case state_data[c.id]
                        when String
                          Time.strptime(state_data[c.id], "%FT%T.%N%Z")
                        when Numeric
                          Time.at(state_data[c.id]).utc
                        when Time
                          state_data[c.id]
                        when NilClass
                          nil
                        else
                          raise ArgumentError, "Unknown type for state data: #{state_data[c.id].inspect}"
                        end

        @containers[c.id] = Mobystash::Container.new(Docker::Container.get(c.id, {}, docker_connection), @config, last_log_time: last_log_time)
        @containers[c.id].run!
      rescue Docker::Error::NotFoundError
        nil
      end
    end
  end

  def run_checkpoint_timer
    @checkpoint_timer_thread = Thread.new do
      loop do
        sleep @config.state_checkpoint_interval
        @queue.push([:checkpoint_state])
      end
    end.tap { |t| t.report_on_exception = false }
  end

  def write_state_file
    File.open("#{@config.state_file}.new", File::WRONLY | File::CREAT | File::TRUNC, 0600) do |fd|
      fd.write Marshal.dump(container_state)
      fd.fdatasync
    end

    File.rename("#{@config.state_file}.new", @config.state_file)
  end

  def container_state
    {}.tap do |state|
      @containers.each do |id, c|
        state[id] = c.last_log_timestamp
      end
    end
  end

  def docker_connection
    @docker_connection ||= Docker::Connection.new(@config.docker_host, {})
  end
end
