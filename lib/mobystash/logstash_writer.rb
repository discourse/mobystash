# frozen_string_literal: true
#
# TODO: decide if we are keeping the extra gem https://raw.githubusercontent.com/discourse/logstash_writer
# or not
require 'ipaddr'
require 'json'
require 'resolv'
require 'socket'

# Write messages to a logstash server.
#
# Flings events, represented as JSON objects, to logstash using the
# `json_lines` codec (over TCP).  Doesn't do any munging or modification of
# the event data given to it, other than adding a `@timestamp` field if
# it doesn't already exist.
#
# We support highly-available logstash installations by means of multiple
# address records, or via SRV records.  See the docs for .new for details
# as to the valid formats for the server.
#
class LogstashWriter

  attr_reader :metrics

  # How long, in seconds, to pause the first time an error is encountered.
  # Each successive error will cause a longer wait, so as to prevent
  # thundering herds.
  INITIAL_RETRY_WAIT = 0.5

  # Create a new logstash writer.
  #
  # Once the object is created, you're ready to give it messages by
  # calling #send_event.  No messages will actually be *delivered* to
  # logstash, though, until you call #run.
  #
  # If multiple addresses are returned from an A/AAAA resolution, or
  # multiple SRV records, then the records will all be tried in random
  # order (for A/AAAA records) or in line with the standard rules for
  # weight and priority (for SRV records).
  #
  # @param server_name [String] details for connecting to the logstash
  #    server(s).  This can be:
  #
  #    * `<IPv4 address>:<port>` -- a literal IPv4 address, and mandatory
  #      port.
  #
  #    * `[<IPv6 address>]:<port>` -- a literal IPv6 address, and mandatory
  #      port.  enclosing the address in square brackets isn't required, but
  #      it's a serving suggestion to make it a little easier to discern
  #      address from port.  Forgetting the include the port will end in
  #      confusion.
  #
  #    * `<hostname>:<port>` -- the given hostname will be resolved for
  #      A/AAAA records, and all returned addresses will be tried in random
  #      order until one is found that accepts a connection.
  #
  #    * `<dnsname>` -- the given dnsname will be resolved for SRV records,
  #      and the returned target hostnames and ports will be tried in the
  #      RFC2782-approved manner according to priority and weight until one
  #      is found which accepts a connection.
  #
  # @param logger [Logger] something to which we can write log entries
  #    for debugging and error-reporting purposes.
  #
  # @param backlog [Integer] a non-negative integer specifying the maximum
  #    number of events that should be queued during periods when the
  #    logstash server is unavailable.  If the limit is exceeded, the oldest
  #    (= first event to be queued) will be dropped.
  #
  # @param metrics_registry [Prometheus::Client::Registry] where to register
  #    the metrics instrumenting the operation of the writer instance.
  #
  # @param metrics_prefix [#to_s] what to prefix all of the metrics used to
  #    instrument the operation of the writer instance.  If you instantiate
  #    multiple LogstashWriter instances with the same `stats_registry`, this
  #    parameter *must* be different for each of them, or you will get some
  #    inscrutable exception raised from the registry.
  #
  def initialize(server_name:, logger: Logger.new("/dev/null"), backlog: 1_000, metrics_prefix: "logstash_writer")
    @server_name, @logger, @backlog = server_name, logger, backlog

    counter = PrometheusExporter::Metric::Counter
    gauge = PrometheusExporter::Metric::Gauge

    @metrics = {
      received: counter.new("#{metrics_prefix}_events_received_total", "The number of logstash events which have been submitted for delivery"),
      sent: counter.new("#{metrics_prefix}_events_written_total", "The number of logstash events which have been delivered to the logstash server"),
      queue_size: gauge.new("#{metrics_prefix}_queue_size", "The number of events currently in the queue to be sent"),
      dropped: counter.new("#{metrics_prefix}_events_dropped_total", "The number of events which have been dropped from the queue"),

      lag: gauge.new("#{metrics_prefix}_last_sent_event_time_seconds", "When the last event successfully sent to logstash was originally received"),

      connected: gauge.new("#{metrics_prefix}_connected_to_server", "Boolean flag indicating whether we are currently connected to a logstash server"),
      connect_exception: counter.new("#{metrics_prefix}_connect_exceptions_total", "The number of exceptions that have occurred whilst attempting to connect to a logstash server"),
      write_exception: counter.new("#{metrics_prefix}_write_exceptions_total", "The number of exceptions that have occurred whilst attempting to write an event to a logstash server"),

      write_loop_exception: counter.new("#{metrics_prefix}_write_loop_exceptions_total", "The number of exceptions that have occurred in the writing loop"),
      write_loop_ok: gauge.new("#{metrics_prefix}_write_loop_ok", "Boolean flag indicating whether the writing loop is currently operating correctly, or is in a post-apocalyptic hellscape of never-ending exceptions"),
      queue_max: gauge.new("#{metrics_prefix}_queue_max", "The maximum size of the event queue")
    }

    @metrics[:queue_max].observe(backlog)

    # We can't use a stdlib Queue object because we need to re-push items
    # onto the front of the queue in case of error
    @queue       = []
    @queue_mutex = Mutex.new
    @queue_cv    = ConditionVariable.new

    @socket_mutex = Mutex.new
    @worker_mutex = Mutex.new
  end

  # Add an event to the queue, to be sent to logstash.  Actual event
  # delivery will happen in a worker thread that is started with
  # #run.  If the event does not have a `@timestamp` field, it will
  # be added set to the current time.
  #
  # @param e [Hash] the event data to be sent.
  #
  # @return [NilClass]
  #
  def send_event(e)
    unless e.is_a?(Hash)
      raise ArgumentError, "Event must be a hash"
    end

    unless e.has_key?(:@timestamp) || e.has_key?("@timestamp")
      e[:@timestamp] = Time.now.utc.strftime("%FT%T.%NZ")
    end

    @queue_mutex.synchronize do
      @queue << { content: e, arrival_timestamp: Time.now }
      while @queue.length > @backlog
        @queue.shift
        stat_dropped
      end
      @queue_cv.signal

      stat_received
    end

    nil
  end

  # Start sending events.
  #
  # This method will return almost immediately, and actual event
  # transmission will commence in a separate thread.
  #
  # @return [NilClass]
  #
  def run
    @worker_mutex.synchronize do
      if @worker_thread.nil?
        @worker_thread = Thread.new do
          Thread.current.name = "LogstashWriter"
          write_loop
        end.tap { |t| t.report_on_exception = false }
      end
    end

    nil
  end

  # Stop the worker thread.
  #
  # Politely ask the worker thread to please finish up once it's
  # finished sending all messages that have been queued.  This will
  # return once the worker thread has finished.
  #
  # @return [NilClass]
  #
  def stop
    @worker_mutex.synchronize do
      if @worker_thread
        @terminate = true
        @queue_cv.signal
        begin
          @worker_thread.join
        rescue Exception => ex
          @logger.error("LogstashWriter") { (["Worker thread terminated with exception: #{ex.message} (#{ex.class})"] + ex.backtrace).join("\n  ") }
        end
        @worker_thread = nil
        @socket_mutex.synchronize { (@current_target.close; @current_target = nil) if @current_target }
      end
    end

    nil
  end

  # Disconnect from the currently-active server.
  #
  # In certain circumstances, you may wish to force the writer to stop
  # sending messages to the currently-connected logstash server, and
  # re-resolve the `server_name` to get new a new address to talk to.
  # Calling this method will cause that to happen.
  #
  # @return [NilClass]
  #
  def force_disconnect!
    @socket_mutex.synchronize do
      return if @current_target.nil?

      @logger.info("LogstashWriter") { "Forced disconnect from #{@current_target.describe_peer}" }
      @current_target.close
      @current_target = nil
    end

    nil
  end

  private

  # The main "worker" method for getting events out of the queue and
  # firing them at logstash.
  #
  def write_loop
    error_wait = INITIAL_RETRY_WAIT

    catch :terminate do
      loop do
        event = nil

        begin
          @queue_mutex.synchronize do
            while @queue.empty? && !@terminate
              @queue_cv.wait(@queue_mutex)
            end

            if @queue.empty? && @terminate
              @terminate = false
              throw :terminate
            end

            event = @queue.shift
          end

          current_target do |t|
            t.socket.puts event[:content].to_json
            stat_sent(t.to_s, event[:arrival_timestamp])
            @metrics[:write_loop_ok].observe(1)
            error_wait = INITIAL_RETRY_WAIT
          end
        rescue StandardError => ex
          @logger.error("LogstashWriter") { (["Exception in write_loop: #{ex.message} (#{ex.class})"] + ex.backtrace).join("\n  ") }
          @queue_mutex.synchronize { @queue.unshift(event) if event }
          @metrics[:write_loop_exception].observe(1, class: ex.class.to_s)
          @metrics[:write_loop_ok].observe(0)
          sleep error_wait
          # Increase the error wait timeout for next time, up to a maximum
          # interval of about 60 seconds
          error_wait *= 1.1
          error_wait = 60 if error_wait > 60
          error_wait += rand / 0.5
        end
      end
    end
  end

  # Yield a Target connected to the server we currently believe to be
  # accepting log entries, so that something can send log entries to it.
  #
  # The yielding allows us to centralise all error detection and handling
  # within this one method, and retry sending just by calling `yield` again
  # when we've connected to another server.
  #
  def current_target
    # This could all be handled more cleanly with recursion, but I don't
    # want to fill the stack if we have to retry a lot of times.  Also
    # can't just use `retry` because not all of the "go around again"
    # conditions are due to exceptions.
    done = false

    until done
      @socket_mutex.synchronize do
        if @current_target
          begin
            # Check that our socket is still good to go; if we don't do
            # this, the other end can disconnect, and because we're never
            # normally reading from the socket, we never get the EOFError
            # that normally results, and so the socket remains in CLOSE_WAIT
            # state *forever*.  raising an ENOTCONN gets us into the
            # SystemCallError rescue, which is where we want to be, and
            # "Transport endpoint is not connected" seems like a suitably
            # appropriate error to me under the circumstances.
            raise Errno::ENOTCONN unless IO.select([@current_target.socket], [], [], 0).nil?

            yield @current_target
            @metrics[:connected].observe(1, server: @current_target.describe_peer)
            done = true
          rescue SystemCallError => ex
            # Something went wrong during the send; disconnect from this
            # server and recycle
            @metrics[:write_exception].increment(server: @current_target.describe_peer, class: ex.class.to_s)
            @metrics[:connected].observe(0, server: @current_target.describe_peer)
            @logger.error("LogstashWriter") { "Error while writing to current server #{@current_target.describe_peer}: #{ex.message} (#{ex.class})" }
            @current_target.close
            @current_target = nil

            sleep INITIAL_RETRY_WAIT
          end
        else
          retry_delay = INITIAL_RETRY_WAIT * 10
          candidates = resolve_server_name
          @logger.debug("LogstashWriter") { "Server candidates: #{candidates.inspect}" }

          if candidates.empty?
            # A useful error message will (should?) have been logged by something
            # down in the bowels of resolve_server_name, so all we have to do
            # is wait a little while, then let the loop retry.
            sleep INITIAL_RETRY_WAIT * 10
          else
            begin
              next_server = candidates.shift

              if next_server
                @logger.debug("LogstashWriter") { "Trying to connect to #{next_server.to_s}" }
                @current_target = next_server
                # Trigger a connection attempt
                @current_target.socket
                @logger.info("LogstashWriter") { "Connected to #{@current_target.describe_peer}" }
              else
                @logger.debug("LogstashWriter") { "Could not connect to any server; pausing before trying again" }
                @current_target = nil
                sleep retry_delay

                # Calculate a longer retry delay next time we fail to connect
                # to every server in the list, up to a maximum of (roughly) 60
                # seconds.
                retry_delay *= 1.5
                retry_delay = 60 if retry_delay > 60
                # A bit of randomness to prevent the thundering herd never goes
                # amiss
                retry_delay += rand
              end
            rescue SystemCallError => ex
              # Connection failed for any number of reasons; try the next one in the list
              @metrics[:connect_exception].increment(server: next_server.to_s, class: ex.class.to_s)
              @logger.error("LogstashWriter") { "Failed to connect to #{next_server.to_s}: #{ex.message} (#{ex.class})" }
              sleep INITIAL_RETRY_WAIT
              retry
            end
          end
        end
      end
    end
  end

  # Turn the server_name given in the constructor into a list of Target
  # objects, suitable for iterating through to find someone to talk to.
  #
  def resolve_server_name
    return [static_target] if static_target

    # The IPv6 literal case should have been taken care of by
    # static_target, so the only two cases we have to deal with
    # here are specified-port (assume A/AAAA) or no port (assume SRV).
    if @server_name =~ /:/
      host, port = @server_name.split(":", 2)
      targets_from_address_record(host, port)
    else
      targets_from_srv_record(host)
    end
  end

  # Figure out whether the server spec we were given looks like an address:port
  # combo (in which case return a memoised target), else return `nil` to let
  # the DNS take over.
  def static_target
    # It is valid to memoize this because address literals don't change
    # their resolution over time.
    @static_target ||= begin
      if @server_name =~ /\A(.*):(\d+)\z/
        begin
          IPAddr.new($1)
        rescue ArgumentError
          # Whatever is on the LHS isn't a recognisable address literal;
          # assume hostname
          nil
        else
          Target.new($1, $2.to_i)
        end
      end
    end
  end

  # Resolve hostname as A/AAAA, and generate randomly-sorted list of Target
  # records from the list of addresses resolved.
  #
  def targets_from_address_record(hostname, port)
    addrs = Resolv::DNS.new.getaddresses(hostname)
    if addrs.empty?
      @logger.warn("LogstashWriter") { "No addresses resolved for server_name #{hostname.inspect}" }
    end
    addrs.sort_by { rand }.map { |a| Target.new(a.to_s, port.to_i) }
  end

  # Resolve the given hostname as a SRV record, and generate a list of
  # Target records from the resources returned.  The list will be arranged
  # in line with the RFC2782-specified algorithm, respecting the weight and
  # priority of the records.
  #
  def targets_from_srv_record(hostname)
    [].tap do |list|
      left = Resolv::DNS.new.getresources(@server_name, Resolv::DNS::Resource::IN::SRV)
      if left.empty?
        @logger.warn("LogstashWriter") { "No SRV records found for server_name #{@server_name.inspect}" }
      end

      # Let the soft-SRV shuffle... BEGIN!
      until left.empty?
        prio = left.map { |rr| rr.priority }.uniq.min
        candidates = left.select { |rr| rr.priority == prio }
        left -= candidates
        candidates.sort_by! { |rr| [rr.weight, rr.target.to_s] }
        until candidates.empty?
          selector = rand(candidates.inject(1) { |n, rr| n + rr.weight })
          chosen = candidates.inject(0) do |n, rr|
            break rr if n + rr.weight >= selector
            n + rr.weight
          end
          candidates.delete(chosen)
          list << Target.new(chosen.target.to_s, chosen.port)
        end
      end
    end
  end

  def stat_received
    @metrics[:received].increment
    @metrics[:queue_size].increment
  end

  def stat_sent(peer, arrived_time)
    @metrics[:sent].increment(server: peer)
    @metrics[:queue_size].decrement
    @metrics[:lag].observe(arrived_time.to_f)
  end

  def stat_dropped
    @metrics[:queue_size].decrement
    @metrics[:dropped].increment
  end

  # An individual target for logstash messages
  #
  # Takes a host and port, gives back a socket to send data down.
  #
  class Target
    # Create a new target.
    #
    # @param addr [String] an IP address or hostname to which to connect.
    #
    # @param port [Integer] the TCP port number, in the range 1-65535.
    #
    # @raise [ArgumentError] if `addr` is not a valid-looking IP address or
    #    hostname, or if the port number is not in the valid range.
    #
    def initialize(addr, port)
      #:nocov:
      unless addr.is_a? String
        raise ArgumentError, "addr #{addr.inspect} is not a string"
      end

      unless port.is_a? Integer
        raise ArgumentError, "port #{port.inspect} is not an integer"
      end

      unless (1..65535).include?(port)
        raise ArgumentError, "invalid port number #{port.inspect} (must be in range 1-65535)"
      end
      #:nocov:

      @addr, @port = addr, port
    end

    # Create a connection.
    #
    # @return [IO] a socket to the target.
    #
    # @raise [SystemCallError] if connection cannot be established
    #    for any reason.
    #
    def socket
      @socket ||= TCPSocket.new(@addr, @port)
    end

    # Shut down the connection.
    #
    # @return [NilClass]
    #
    def close
      @socket.close if @socket
      @socket = nil
      @describe_peer = nil
    end

    # Simple string representation of the target.
    #
    # @return [String]
    #
    def to_s
      "#{@addr}:#{@port}"
    end

    # Provide as accurate a representation of what we're *actually* connected
    # to as we can, given the constraints of whether we're connected.
    #
    # To prevent unpleasantness when the other end disconnects but we still
    # want to know who we *were* connected to, we cache the result of our
    # cogitations.  Just in case.
    #
    # @return [String]
    #
    def describe_peer
      @describe_peer ||= begin
        if @socket
          pa = @socket.peeraddr
          if pa[0] == "AF_INET6"
            "[#{pa[3]}]:#{pa[1]}"
          else
            "#{pa[3]}:#{pa[1]}"
          end
        else
          nil
        end
      rescue Errno::ENOTCONN
        # Peer disconnected apparently means "I forgot who I was connected
        # to"... ¯\_(ツ)_/¯
        nil
      end || to_s
    end
  end

  private_constant :Target
end
