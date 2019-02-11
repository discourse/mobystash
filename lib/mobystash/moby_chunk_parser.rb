# frozen_string_literal: true

module Mobystash
  # Turn the chunks of data that come out of a Docker log stream into useful
  # lines of logs.
  #
  class MobyChunkParser
    # Raised if the chunk doesn't meet the spec
    class InvalidChunkError < StandardError; end

    # Spawn a chunk parser.
    #
    # This turns a sequence of chunks coming from the `/logs` container
    # endpoint into successive calls to a provided callback block.
    #
    # @param tty [Boolean] whether the chunks we're parsing come from a TTY
    #   container (in which case the format is just lines of text), or not
    #   (in which case it's some sort of binary blob.  The TTYishness of a
    #   container's logs is indicated by the Config.Tty item in the
    #   container's info.
    #
    # @yieldparam msg [String] the log entry.
    #
    # @yieldparam stream [Symbol] one of `:stdout`, `:stderr`, or `:tty`.
    #   For TTY-enabled containers, this will always be `:tty`, otherwise
    #   it'll be `:stdout` or `:stderr` depending on which fd the container
    #   wrote the line on.
    #
    def initialize(tty:, &blk)
      unless blk
        raise ArgumentError,
              "No block given"
      end

      @tty, @blk = tty, blk
      @buf = ""
    end

    # Process a chunk.
    #
    # This is what Excon use to feed us chunks.
    #
    # @param c [String] the chunk itself.
    # @param r [Integer] ignored.
    # @param t [Integer] ignored.
    #
    def call(c, r, t)
      if @tty
        @blk.call(c, :tty)
      else
        decode_chunk(c)
      end
    end

    private

    def decode_chunk(c)
      c = @buf + c

      until c.empty?
        hdr = c.slice!(0, 8)
        if hdr.length < 8
          @buf = hdr
          return
        end
        type, len = hdr.unpack("CxxxN")

        if c.length < len
          @buf = hdr + c
          return
        end

        msg = c.slice!(0, len)
        if type == 1
          @blk.call(msg, :stdout)
        elsif type == 2
          @blk.call(msg, :stderr)
        else
          raise InvalidChunkError,
                "Unknown type value: #{type} (chunk hdr: #{hdr})"
        end
      end
    end
  end
end
