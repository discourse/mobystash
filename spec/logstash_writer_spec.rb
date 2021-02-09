require_relative './spec_helper'

require 'logger'

describe LogstashWriter do
  let(:mock_socket) { double(TCPSocket) }
  let(:mock_target) { double(LogstashWriter.const_get(:Target)) }
  let(:mock_logger) { double(Logger) }
  let(:writer) { LogstashWriter.new(server_name: "192.0.2.1:5151", backlog: 3, logger: mock_logger) }

  before(:each) do
    allow(mock_logger).to receive(:debug)
    allow(mock_logger).to receive(:info)
    allow(mock_logger).to receive(:error) { |p, &m| puts "#{p}: #{m.call}" }
    allow(TCPSocket).to receive(:new).and_return(mock_socket)
    allow(mock_socket).to receive(:close)
    allow(mock_socket).to receive(:peeraddr).and_return(["AF_INET", 5151, "192.0.2.42", "192.0.2.42"])
    # This is only necessary because if we try to pass a mock socket into the
    # real select, it raises an epic hissy-fit
    allow(IO).to receive(:select).and_return(nil)
  end

  describe '.new' do
    it "creates a new LogstashWriter with just a server_name" do
      expect(LogstashWriter.new(server_name: "192.0.2.1:5151")).to be_a(LogstashWriter)
    end
  end

  describe "#send_event" do
    it "queues an event" do
      writer.send_event(ohai: "there")

      expect(writer.instance_variable_get(:@queue).length).to eq(1)
    end

    it "accepts a hash event" do
      expect { writer.send_event(ohai: "there") }.to_not raise_error
    end

    it "does not accept an array of events" do
      expect { writer.send_event([{ ohai: "there" }, { something: "funny" }]) }.to raise_error(ArgumentError)
    end

    it "adds a missing @timestamp" do
      writer.send_event(ohai: "there")

      expect(writer.instance_variable_get(:@queue).first[:content]).to have_key(:@timestamp)
    end

    context "when backlog overflows" do
      before(:each) { 5.times { |i| writer.send_event(ohai: "there no. #{i}") } }

      it "keeps the queue size bounded by backlog" do
        expect(writer.instance_variable_get(:@queue).length).to eq(3)
      end

      it "discards the oldest messages" do
        expect(writer.instance_variable_get(:@queue).first[:content][:ohai]).to eq("there no. 2")
        expect(writer.instance_variable_get(:@queue).last[:content][:ohai]).to eq("there no. 4")
      end
    end
  end

  describe "#run" do
    after(:each) { writer.stop }

    it "starts the worker thread" do
      writer.run

      expect(writer.instance_variable_get(:@worker_thread)).to_not be(nil)
    end

    it "Doesn't start multiple worker threads" do
      writer.run
      wt = writer.instance_variable_get(:@worker_thread).object_id
      writer.run

      expect(writer.instance_variable_get(:@worker_thread).object_id).to eq(wt)
    end
  end

  describe "#stop" do
    it "does nothing if not already running" do
      expect { writer.stop }.to_not raise_error
    end

    it "terminates the worker thread" do
      writer.run
      wt = writer.instance_variable_get(:@worker_thread)

      expect { writer.stop }.to_not raise_error
      expect(writer.instance_variable_get(:@worker_thread)).to be_nil

      expect(wt).to_not be_alive
    end

    it "logs the exception if the worker thread raised one" do
      expect(writer).to receive(:write_loop).and_raise(RuntimeError)

      writer.run

      expect(mock_logger).to receive(:error) do |progname, &msg|
        expect(progname).to eq("LogstashWriter")
        expect(msg.call).to match(/Worker thread terminated.*RuntimeError/)
      end

      expect { writer.stop }.to_not raise_error
    end

    it "closes the current socket" do
      writer.run
      writer.instance_variable_set(:@current_target, mock_target)
      expect(mock_target).to receive(:close)

      writer.stop
    end
  end

  describe "#force_disconnect!" do
    it "does nothing if not connected" do
      expect(mock_logger).to_not receive(:info)

      writer.force_disconnect!
    end

    it "disconnects if connected" do
      writer.instance_variable_set(:@current_target, mock_target)
      allow(mock_target).to receive(:describe_peer).and_return("sometargetaddr")
      expect(mock_logger).to receive(:info) do |progname, &msg|
        expect(progname).to eq("LogstashWriter")
        expect(msg.call).to match(/disconnect.*sometargetaddr/i)
      end
      expect(mock_target).to receive(:close)

      writer.force_disconnect!

      expect(writer.instance_variable_get(:@current_target)).to be_nil
    end
  end

  describe "#write_loop" do
    after(:each) { writer.stop }

    it "sends a message if there is one" do
      allow(mock_logger).to receive(:error) { |p, &m| puts "#{p}: #{m.call}" }
      writer.send_event(ohai: "there")

      expect(mock_socket).to receive(:puts) do |msg|
        expect { JSON.parse(msg) }.to_not raise_error
        raw_msg = JSON.parse(msg)
        expect(raw_msg["ohai"]).to eq("there")
        expect(raw_msg["@timestamp"]).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{9}Z\z/)
      end

      writer.run
      writer.stop
    end

    it "logs an error and pauses if an exception occurs" do
      expect(writer).to receive(:current_target).and_raise(RuntimeError).once
      expect(writer).to receive(:current_target).and_call_original

      expect_log_message(mock_logger, :error, "LogstashWriter", /Exception in write_loop.*RuntimeError/)
      expect(writer).to receive(:sleep).with(0.5)

      allow(mock_socket).to receive(:puts)

      writer.send_event(ohai: "there")

      writer.run
      writer.stop
    end
  end

  describe "#current_target" do
    it "yields a Target object" do
      expect { |b| writer.__send__(:current_target, &b) }.to yield_with_args(instance_of(LogstashWriter.const_get(:Target)))
    end

    it "checks that the socket hasn't closed underneath us" do
      expect(IO).to receive(:select).with([mock_socket], [], [], 0).and_return(nil)

      writer.__send__(:current_target) { nil }
    end

    it "recycles with an error if the socket has closed underneath us" do
      expect(IO).to receive(:select).with([mock_socket], [], [], 0).and_return([[mock_socket], [], []])
      expect(writer).to receive(:sleep).with(0.5)
      expect_log_message(mock_logger, :error, "LogstashWriter", /Error while writing.*ENOTCONN/)

      writer.__send__(:current_target) { nil }
    end

    it "logs and retries if the block raises a SystemCallError" do
      expect(writer).to receive(:sleep).with(0.5)
      expect_log_message(mock_logger, :error, "LogstashWriter", /Error while writing.*EBADF/)

      do_err = true
      expect { writer.__send__(:current_target) { (do_err = false; raise Errno::EBADF) if do_err } }.to_not raise_error
    end

    it "logs an error and tries again if the connection fails with a SystemCallError" do
      expect(TCPSocket).to receive(:new).with("192.0.2.1", 5151).and_raise(Errno::ENOSTR)
      expect(TCPSocket).to receive(:new).with("192.0.2.1", 5151).and_return(mock_socket)
      allow(writer).to receive(:sleep)
      expect_log_message(mock_logger, :error, "LogstashWriter", /Failed to connect.*ENOSTR/)

      writer.__send__(:current_target) { nil }
    end

    it "waits a little while if no candidate servers were found" do
      expect(writer).to receive(:resolve_server_name).and_return([]).ordered
      expect(writer).to receive(:sleep).with(5).ordered
      expect(writer).to receive(:resolve_server_name).and_call_original.ordered

      writer.__send__(:current_target) { nil }
    end
  end

  describe "#resolve_server_name" do
    it "handles an IPv4 static address" do
      writer.instance_variable_set(:@server_name, "192.0.2.42:12345")
      expect(TCPSocket).to receive(:new).with("192.0.2.42", 12345)

      rsn = writer.__send__(:resolve_server_name)
      expect(rsn).to be_a(Array)
      expect(rsn.length).to eq(1)
      rsn.first.socket
    end

    it "handles an unbracketed IPv6 static address" do
      writer.instance_variable_set(:@server_name, "2001:db8::42:6789")
      expect(TCPSocket).to receive(:new).with("2001:db8::42", 6789)

      rsn = writer.__send__(:resolve_server_name)
      expect(rsn).to be_a(Array)
      expect(rsn.length).to eq(1)
      rsn.first.socket
    end

    it "handles a bracketed IPv6 static address" do
      writer.instance_variable_set(:@server_name, "[2001:db8::42]:5432")
      expect(TCPSocket).to receive(:new).with("[2001:db8::42]", 5432)

      rsn = writer.__send__(:resolve_server_name)
      expect(rsn).to be_a(Array)
      expect(rsn.length).to eq(1)
      rsn.first.socket
    end

    it "handles a hostname:port pair" do
      writer.instance_variable_set(:@server_name, "logstash:5151")
      expect(Resolv::DNS).to receive(:new).and_return(mock_resolv = double(Resolv::DNS))
      expect(mock_resolv).to receive(:getaddresses).with("logstash").and_return([Resolv::IPv4.create("192.0.2.42"), Resolv::IPv6.create("2001:db8::42")])

      expect(TCPSocket).to receive(:new).with("192.0.2.42", 5151)
      expect(TCPSocket).to receive(:new).with("2001:db8::42", 5151)

      rsn = writer.__send__(:resolve_server_name)
      expect(rsn).to be_a(Array)
      expect(rsn.length).to eq(2)
      rsn.each { |t| t.socket }
    end

    it "handles a hostname:port pair with no addresses" do
      writer.instance_variable_set(:@server_name, "logstash:5151")
      expect(Resolv::DNS).to receive(:new).and_return(mock_resolv = double(Resolv::DNS))
      expect(mock_resolv).to receive(:getaddresses).with("logstash").and_return([])
      expect_log_message(mock_logger, :warn, "LogstashWriter", /No addresses resolved.*logstash/)

      expect(writer.__send__(:resolve_server_name)).to eq([])
    end

    it "handles a SRV record" do
      writer.instance_variable_set(:@server_name, "logstash._tcp")
      expect(Resolv::DNS).to receive(:new).and_return(mock_resolv = double(Resolv::DNS))
      expect(mock_resolv).to receive(:getresources)
        .with("logstash._tcp", Resolv::DNS::Resource::IN::SRV)
        .and_return([
          Resolv::DNS::Resource::IN::SRV.new(10, 100, 1234, "foo.example.com"),
          Resolv::DNS::Resource::IN::SRV.new(10, 100, 5678, "bar.example.com"),
          Resolv::DNS::Resource::IN::SRV.new(10, 100, 9876, "baz.example.com"),
        ])

      expect(TCPSocket).to receive(:new).with("foo.example.com", 1234)
      expect(TCPSocket).to receive(:new).with("bar.example.com", 5678)
      expect(TCPSocket).to receive(:new).with("baz.example.com", 9876)

      rsn = writer.__send__(:resolve_server_name)
      expect(rsn).to be_a(Array)
      expect(rsn.length).to eq(3)
      rsn.each { |t| t.socket }
    end

    it "handles a SRV record with disparate priorities" do
      writer.instance_variable_set(:@server_name, "logstash._tcp")
      expect(Resolv::DNS).to receive(:new).and_return(mock_resolv = double(Resolv::DNS))
      expect(mock_resolv).to receive(:getresources)
        .with("logstash._tcp", Resolv::DNS::Resource::IN::SRV)
        .and_return([
          Resolv::DNS::Resource::IN::SRV.new(10, 100, 1234, "foo.example.com"),
          Resolv::DNS::Resource::IN::SRV.new(20, 100, 5678, "bar.example.com"),
        ])

      expect(TCPSocket).to receive(:new).with("foo.example.com", 1234).ordered
      expect(TCPSocket).to receive(:new).with("bar.example.com", 5678).ordered

      rsn = writer.__send__(:resolve_server_name)
      expect(rsn).to be_a(Array)
      expect(rsn.length).to eq(2)
      rsn.each { |t| t.socket }
    end

    it "handles a SRV record with no results" do
      writer.instance_variable_set(:@server_name, "logstash._tcp")
      expect(Resolv::DNS).to receive(:new).and_return(mock_resolv = double(Resolv::DNS))
      expect(mock_resolv).to receive(:getresources)
        .with("logstash._tcp", Resolv::DNS::Resource::IN::SRV)
        .and_return([])

      expect_log_message(mock_logger, :warn, "LogstashWriter", /No SRV records found.*logstash._tcp/)

      expect(writer.__send__(:resolve_server_name)).to eq([])
    end
  end
end

describe "LogstashWriter::Target" do
  let(:klass) { LogstashWriter.const_get(:Target) }
  let(:mock_socket) { instance_double(TCPSocket) }

  before(:each) do
    allow(TCPSocket).to receive(:new).and_return(mock_socket)
    allow(mock_socket).to receive(:close)
  end

  describe "#to_s" do
    context "an IPv4 target" do
      let(:target) { klass.new("192.0.2.123", 5151) }

      it "returns the addr/port" do
        expect(target.to_s).to eq("192.0.2.123:5151")
      end
    end

    context "an IPv6 target" do
      let(:target) { klass.new("2001:db8::123", 5151) }

      it "returns the addr/port" do
        expect(target.to_s).to eq("2001:db8::123:5151")
      end
    end
  end

  describe "#describe_peer" do
    context "an IPv4 peer" do
      let(:target) { klass.new("192.0.2.123", 5151) }

      it "falls back to the string if there's no peer" do
        expect(target.describe_peer).to eq(target.to_s)
      end

      it "returns the peeraddr if there's a socket" do
        expect(mock_socket).to receive(:peeraddr).and_return(["AF_INET", 5151, "192.0.2.42", "192.0.2.42"])
        # Get the socket prepped
        target.socket

        expect(target.describe_peer).to eq("192.0.2.42:5151")
      end

      it "caches the peeraddr after the first request" do
        expect(mock_socket).to receive(:peeraddr).and_return(["AF_INET", 5151, "192.0.2.42", "192.0.2.42"]).exactly(:once)
        # Get the socket prepped
        target.socket
        # Initial read
        target.describe_peer

        # Now the real test
        expect(target.describe_peer).to eq("192.0.2.42:5151")
      end

      it "clears the peeraddr cache after close" do
        expect(mock_socket).to receive(:peeraddr).and_return(["AF_INET", 5151, "192.0.2.42", "192.0.2.42"]).exactly(:once)
        target.socket
        expect(target.describe_peer).to eq("192.0.2.42:5151")

        target.close

        expect(target.describe_peer).to eq("192.0.2.123:5151")
      end

      it "falls back to the string if the peer is perma-disconnected" do
        expect(mock_socket).to receive(:peeraddr).and_raise(Errno::ENOTCONN)
        target.socket

        expect(target.describe_peer).to eq("192.0.2.123:5151")
      end
    end

    context "an IPv6 peer" do
      let(:target) { klass.new("2001:db8::123", 5151) }

      it "falls back to the string if there's no peer" do
        expect(target.describe_peer).to eq(target.to_s)
      end

      it "returns the peeraddr if there's a socket" do
        expect(mock_socket).to receive(:peeraddr).and_return(["AF_INET6", 5151, "2001:db8::42", "2001:db8::42"])
        # Get the socket prepped
        target.socket

        expect(target.describe_peer).to eq("[2001:db8::42]:5151")
      end

      it "caches the peeraddr after the first request" do
        expect(mock_socket).to receive(:peeraddr).and_return(["AF_INET6", 5151, "2001:db8::42", "2001:db8::42"]).exactly(:once)
        # Get the socket prepped
        target.socket
        # Initial read
        target.describe_peer

        # Now the real test
        expect(target.describe_peer).to eq("[2001:db8::42]:5151")
      end

      it "clears the peeraddr cache after close" do
        expect(mock_socket).to receive(:peeraddr).and_return(["AF_INET6", 5151, "2001:db8::42", "2001:db8::42"]).exactly(:once)
        target.socket
        expect(target.describe_peer).to eq("[2001:db8::42]:5151")

        target.close

        expect(target.describe_peer).to eq("2001:db8::123:5151")
      end

      it "falls back to the string if the peer is perma-disconnected" do
        expect(mock_socket).to receive(:peeraddr).and_raise(Errno::ENOTCONN)
        target.socket

        expect(target.describe_peer).to eq("2001:db8::123:5151")
      end
    end
  end
end
