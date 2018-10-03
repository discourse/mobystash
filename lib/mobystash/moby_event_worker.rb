require 'docker-api'
require 'thread'

require 'mobystash/log_exception'

module Mobystash
  # A module containing the common code needed to process some sort of event
  # stream from Moby in a background thread, handling starting and stopping
  # the thread, catching and handling all manner of weird errors and
  # brainfarts from the Docker API, and maintaining basic metrics.
  #
  # What you get:
  #
  # * `run`, `run!` (run in a background worker thread) and `shutdown!`
  #   (stop the background worker thread) methods.
  #
  # * Automatically catch and log/instrument errors.
  #
  # This module relies on the following methods being available:
  #
  # * **`process_events`**, which will be called in a loop to do...things.
  #   It takes a single argument, a `Docker::Connection` object, which you
  #   can use to do the needful.
  #
  #   Any exceptions raised by this method will be caught, logged, and
  #   `process_events` called again.
  #
  # * **`docker_host`**, which should return a string containing a URL to
  #   the Moby server to connect to.
  #
  # * **`progname`**, which should return a string which will be used as
  #   the `progname` parameter to the logger.
  #
  # * **`logger`**, which should return a `Logger` instance, or at least
  #   a reasonable simulacrum thereof.
  #
  # * **`event_exception`**, which will be passed an exception object whenever
  #   an exception is raised by `process_events`.  Useful if you want to
  #   instrument exceptions being raised in the event worker (which you should,
  #   because it's awesome).
  #
  # You must also call `super` in your class' `initialize` method, otherwise
  # certain rather important instance variables will not be initialized, to
  # your great and lasting detriment.

  module MobyEventWorker
    include LogException

    # Raise this exception in the thread to signal termination.
    class TerminateEventWorker < Exception; end
    private_constant :TerminateEventWorker

    # All I wanted to do was initialize a mutex... *sob*
    def initialize(*_)
      @event_worker_thread_mutex = Mutex.new

      begin
        # This is all a bit of a nightmare.  We want to "transparently"
        # pass-through arguments from the initializer of the class we
        # were included in, through to the initializer of our class'
        # parent, if specified.  The problem is that if the class we
        # were included in doesn't *have* a specific parent you'd want
        # to pass arguments into, this call to super will call the
        # initializer for Object, which exists, and which takes no
        # arguments.  This causes quite a ruckus.  So, we need to
        # catch the exception that comes when you try to pass arguments
        # to an initializer that doesn't take them, and try again without.
        super
      rescue ArgumentError => ex
        if ex.message =~ /wrong number of arguments.*expected 0/
          super()
        else
          #:nocov:
          raise
          #:nocov:
        end
      end
    end

    # Main action loop, runs in current thread.  If you want to run this in
    # the background, look at #run! instead.
    def run
      conn = Docker::Connection.new(docker_host, read_timeout: 3600)

      loop { process_events(conn) }
    rescue TerminateEventWorker
      # See ya!
    rescue Docker::Error::TimeoutError
      retry
    rescue Excon::Error::Socket => ex
      log_exception(ex, :debug) { "Got socket error while listening for events" }
      sleep 1
      retry
    rescue StandardError => ex
      log_exception(ex) { "Event runner raised exception" }
      event_exception(ex)
      sleep 1
      retry
    end

    # Async stuff is a right shit to test, and frankly the sorts of bugs that
    # crop up in this stuff are the sort of concurrency shitshows that don't
    # reliably get found by testing anyway.  So...
    #:nocov:
    def run!
      @event_worker_thread_mutex.synchronize do
        return if @event_worker_thread

        @event_worker_thread = Thread.new do
          @logger.debug(progname) { "MobyEventWorker thread #{Thread.current.object_id} starting" }
          begin
            self.run
          rescue Exception => ex
            log_exception(ex) { "MobyEventWorker thread #{Thread.current.object_id} received fatal exception" }
          else
            @logger.debug(progname) { "MobyEventWorker thread #{Thread.current.object_id} terminating" }
          end
        end
      end
    end

    # Shut down the worker thread.
    def shutdown!
      @event_worker_thread_mutex.synchronize do
        return if @event_worker_thread.nil?

        @event_worker_thread.raise(TerminateEventWorker)
        @event_worker_thread.join
        @event_worker_thread = nil
      end
    end
    #:nocov:

    private

    def progname
      #:nocov:
      @logger_progname ||= "UnconfiguredMobyEventWorker"
      #:nocov:
    end

    def docker_host
      #:nocov:
      ENV.fetch("DOCKER_HOST", "unix:///var/run/docker.sock")
      #:nocov:
    end
  end
end
