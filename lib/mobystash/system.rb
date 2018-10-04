require 'frankenstein/server'
require 'frankenstein/process_metrics'
require 'frankenstein/ruby_gc_metrics'
require 'logger'
require 'logstash_writer'

require 'mobystash/config'
require 'mobystash/moby_watcher'

# All things Mobystash.
module Mobystash
  # The core system, responsible for spawning all other threads and routing
  # and handling messages.
  class System
    attr_reader :config

    # Create a new mobystash system.
    #
    # @param env [Hash] the set of environment variables with which to
    #   configure the system.
    #
    # @param logger [Logger] pass in a custom logger to the system.
    #
    # @return [Mobystash::System]
    #
    # @raise [Mobystash::Config::InvalidEnvironmentError] if any problems
    #   are detected with the environment variables found.
    #
    def initialize(env, logger:)
      @config     = Mobystash::Config.new(env, logger: logger)
      @logger     = logger
      @queue      = Queue.new
      @watcher    = Mobystash::MobyWatcher.new(queue: @queue, config: @config)
      @containers = {}
    end

    # Start everything up!
    def run
      @watcher.run!
      @config.logstash_writer.run

      if @config.enable_metrics
        @logger.info(progname) { "Starting metrics server" }
        Frankenstein::ProcessMetrics.register(@config.metrics_registry)
        Frankenstein::RubyGCMetrics.register(@config.metrics_registry)

        @metrics_server = Frankenstein::Server.new(port: 9367, logger: @logger, registry: @config.metrics_registry, metrics_prefix: :mobystash_metrics)
        @metrics_server.run
      end

      run_existing_containers

      @logger.info(progname) { "Commencing real-time log collection" }

      loop do
        item = @queue.pop
        @logger.debug(progname) { "Received message #{item.inspect}" }

        case (item.first rescue nil)
        when :created
          begin
            unless @containers[item.last]
              @containers[item.last] = Mobystash::Container.new(Docker::Container.get(item.last, {}, docker_connection), @config)
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
        when :terminate
          @logger.info(progname) { "Terminating." }
          @watcher.shutdown!
          @containers.values.each { |c| c.shutdown! }
          @config.logstash_writer.stop
          @metrics_server.shutdown if @metrics_server
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
      @config.logstash_writer.force_disconnect!
    end

    private

    def progname
      "Mobystash::System"
    end

    def run_existing_containers
      @logger.info(progname) { "Collecting logs for existing containers" }

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
          @containers[c.id] = Mobystash::Container.new(Docker::Container.get(c.id, {}, docker_connection), @config)
          @containers[c.id].run!
        rescue Docker::Error::NotFoundError
          nil
        end
      end
    end

    def docker_connection
      @docker_connection ||= Docker::Connection.new(@config.docker_host, {})
    end
  end
end
