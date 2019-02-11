# frozen_string_literal: true

module Mobystash
  # Helper to log exceptions.
  module LogException
    # Sick of writing this all out every time
    def log_exception(ex, sev = :error)
      logger.__send__(sev, progname) { (["#{yield}: #{ex.message} (#{ex.class})"] + ex.backtrace).join("\n  ") }
    end
  end
end
