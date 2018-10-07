require_relative './spec_helper'

require 'mobystash/config'
require 'mobystash/container'

describe Mobystash::Container do
  DOC_ID_REGEX = /\A[A-Za-z0-9+\/]{22}\z/.freeze

  uses_logger

  let(:env) do
    {
      "LOGSTASH_SERVER" => "speccy",
    }
  end

  let(:mock_writer) { instance_double(LogstashWriter) }
  let(:config)      { Mobystash::Config.new(env, logger: logger) }
  let(:docker_data) { container_fixture(container_name) }
  let(:container)   { Mobystash::Container.new(docker_data, config) }

  before :each do
    allow(LogstashWriter).to receive(:new).with(server_name: "speccy", logger: logger, backlog: 1_000_000, metrics_registry: instance_of(Prometheus::Client::Registry)).and_return(mock_writer)
    allow(Docker::Connection).to receive(:new).with("unix:///", {}).and_call_original
  end

  describe ".new" do
    context "basic container" do
      let(:container_name) { "basic_container" }

      it "creates the container object" do
        expect(container).to be_a(Mobystash::Container)
      end
    end
  end

  describe "#run" do
    let(:mock_conn)           { instance_double(Docker::Connection) }
    let(:mock_moby_container) { instance_double(Docker::Container) }

    before(:each) do
      allow(Docker::Connection).to receive(:new).with("unix:///var/run/docker.sock", read_timeout: 3600).and_return(mock_conn)
      allow(mock_conn).to receive(:get).and_raise(Mobystash::MobyEventWorker.const_get(:TerminateEventWorker))
      allow(Docker::Container).to receive(:new).with(instance_of(Docker::Connection), instance_of(Hash)).and_call_original
      allow(Docker::Container).to receive(:get).with(container_id, {}, mock_conn).and_return(mock_moby_container)
      allow(mock_moby_container).to receive(:info).and_return("Config" => { "Tty" => false })

      # I'm a bit miffed we have to do this; to my mind, a double should
      # lie a little
      allow(mock_conn).to receive(:is_a?).with(Docker::Connection).and_return(true)
    end

    context "basic container" do
      let(:container_name) { "basic_container" }
      let(:container_id)   { "asdfasdfbasic" }

      it "asks for logs" do
        expect(mock_conn)
          .to receive(:get)
          .with("/containers/asdfasdfbasic/logs",
            { timestamps: true, stdout: true, stderr: true, follow: true, since: "0.000000000" },
            response_block: instance_of(Mobystash::MobyChunkParser)
          )
          .and_raise(Mobystash::MobyEventWorker.const_get(:TerminateEventWorker))

        container.run
      end

      it "forwards logs" do
        expect(mock_conn)
          .to receive(:get) do |path, opts, excon_opts|
            expect(path).to eq("/containers/asdfasdfbasic/logs")
            expect(opts).to eq(timestamps: true, stdout: true, stderr: true, follow: true, since: "0.000000000")
            expect(excon_opts).to have_key(:response_block)
            expect(excon_opts[:response_block]).to be_a(Mobystash::MobyChunkParser)

            excon_opts[:response_block].call("\x01\x00\x00\x00\x00\x00\x00$2018-10-02T08:39:16.458228203Z xyzzy", 0, 0)
          end.ordered.and_return(nil)
        expect(mock_conn)
          .to receive(:get)
          .with("/containers/asdfasdfbasic/logs",
            { timestamps: true, stdout: true, stderr: true, follow: true, since: "1538469556.458228203" },
            response_block: instance_of(Mobystash::MobyChunkParser)
          )
          .and_raise(Mobystash::MobyEventWorker.const_get(:TerminateEventWorker))

        expect(mock_writer)
          .to receive(:send_event)
          .with(
            message:      "xyzzy",
            moby:         {
              name:     "basic_container",
              id:       "asdfasdfbasic",
              hostname: "basic-container",
              image:    "rspec/basic_container:latest",
              image_id: "poiuytrewqbasic",
              stream:   "stdout",
            },
            "@timestamp": "2018-10-02T08:39:16.458228203Z",
            "@metadata":  {
              document_id: match(DOC_ID_REGEX),
              event_type:  "moby",
            },
          )

        container.run
      end

      it "asks for new logs next time around" do
        allow(mock_writer).to receive(:send_event)

        expect(mock_conn)
          .to receive(:get) do |path, opts, excon_opts|
            expect(path).to eq("/containers/asdfasdfbasic/logs")
            expect(opts).to eq(timestamps: true, stdout: true, stderr: true, follow: true, since: "0.000000000")
            expect(excon_opts).to have_key(:response_block)
            expect(excon_opts[:response_block]).to be_a(Mobystash::MobyChunkParser)

            excon_opts[:response_block].call("\x01\x00\x00\x00\x00\x00\x00 2009-02-13T23:31:30.987654321Z A", 0, 0)
          end.ordered.and_return(nil)
        expect(mock_conn)
          .to receive(:get)
          .with("/containers/asdfasdfbasic/logs",
            { timestamps: true, stdout: true, stderr: true, follow: true, since: "1234567890.987654321" },
            response_block: instance_of(Mobystash::MobyChunkParser)
          )
          .and_raise(Mobystash::MobyEventWorker.const_get(:TerminateEventWorker))

        container.run
      end
    end

    context "mobystash-disabled container" do
      let(:container_name) { "disabled_container" }
      let(:container_id)   { "asdfasdfdisabled" }

      it "does not ask for logs" do
        expect(Docker::Container).to_not receive(:get)
        expect(container).to receive(:sleep).with(no_args).and_raise(Mobystash::MobyEventWorker.const_get(:TerminateEventWorker))

        container.run
      end
    end

    context "mobystash-filtered container" do
      let(:container_name) { "filtered_container" }
      let(:container_id)   { "asdfasdffiltered" }

      it "asks for logs" do
        expect(mock_conn)
          .to receive(:get)
          .with("/containers/asdfasdffiltered/logs",
            { timestamps: true, stdout: true, stderr: true, follow: true, since: "0.000000000" },
            response_block: instance_of(Mobystash::MobyChunkParser)
          )
          .and_raise(Mobystash::MobyEventWorker.const_get(:TerminateEventWorker))

        container.run
      end

      it "forwards logs not matching the regex" do
        expect(mock_conn)
          .to receive(:get) do |path, opts, excon_opts|
            expect(path).to eq("/containers/asdfasdffiltered/logs")
            expect(opts).to eq(timestamps: true, stdout: true, stderr: true, follow: true, since: "0.000000000")
            expect(excon_opts).to have_key(:response_block)
            expect(excon_opts[:response_block]).to be_a(Mobystash::MobyChunkParser)

            excon_opts[:response_block].call("\x01\x00\x00\x00\x00\x00\x00 2018-10-02T08:39:16.458228203Z A", 0, 0)
          end.ordered.and_return(nil)
        expect(mock_conn)
          .to receive(:get)
          .with("/containers/asdfasdffiltered/logs",
            { timestamps: true, stdout: true, stderr: true, follow: true, since: "1538469556.458228203" },
            response_block: instance_of(Mobystash::MobyChunkParser)
          )
          .and_raise(Mobystash::MobyEventWorker.const_get(:TerminateEventWorker))

        expect(mock_writer)
          .to receive(:send_event)
          .with(
            message:      "A",
            moby:         {
              name:     "filtered_container",
              id:       "asdfasdffiltered",
              hostname: "filtered-container",
              image:    "rspec/filtered_container:latest",
              image_id: "poiuytrewqfiltered",
              stream:   "stdout",
            },
            "@timestamp": "2018-10-02T08:39:16.458228203Z",
            "@metadata":  {
              document_id: match(DOC_ID_REGEX),
              event_type:  "moby",
            },
          )

        container.run
      end

      it "doesn't forward logs matching the filter regex" do
        expect(mock_conn)
          .to receive(:get) do |path, opts, excon_opts|
            expect(path).to eq("/containers/asdfasdffiltered/logs")
            expect(opts).to eq(timestamps: true, stdout: true, stderr: true, follow: true, since: "0.000000000")
            expect(excon_opts).to have_key(:response_block)
            expect(excon_opts[:response_block]).to be_a(Mobystash::MobyChunkParser)

            excon_opts[:response_block].call("\x01\x00\x00\x00\x00\x00\x00 2018-10-02T08:39:16.458228203Z Z", 0, 0)
          end.ordered.and_return(nil)
        expect(mock_conn)
          .to receive(:get)
          .with("/containers/asdfasdffiltered/logs",
            { timestamps: true, stdout: true, stderr: true, follow: true, since: "1538469556.458228203" },
            response_block: instance_of(Mobystash::MobyChunkParser)
          )
          .and_raise(Mobystash::MobyEventWorker.const_get(:TerminateEventWorker))

        expect(mock_writer).to_not receive(:send_event)

        container.run
      end
    end

    context "mobystash-tagged container" do
      let(:container_name) { "tagged_container" }
      let(:container_id)   { "asdfasdftagged" }

      it "asks for logs" do
        expect(mock_conn)
          .to receive(:get)
          .with("/containers/asdfasdftagged/logs",
            { timestamps: true, stdout: true, stderr: true, follow: true, since: "0.000000000" },
            response_block: instance_of(Mobystash::MobyChunkParser)
          ).and_raise(Mobystash::MobyEventWorker.const_get(:TerminateEventWorker))

        container.run
      end

      it "sends events with the extra tags" do
        expect(mock_conn)
          .to receive(:get) do |path, opts, excon_opts|
            expect(path).to eq("/containers/asdfasdftagged/logs")
            expect(opts).to eq(timestamps: true, stdout: true, stderr: true, follow: true, since: "0.000000000")
            expect(excon_opts).to have_key(:response_block)
            expect(excon_opts[:response_block]).to be_a(Mobystash::MobyChunkParser)

            excon_opts[:response_block].call("\x01\x00\x00\x00\x00\x00\x00 2018-10-02T08:39:16.458228203Z A", 0, 0)
          end.ordered.and_return(nil)
        expect(mock_conn)
          .to receive(:get)
          .with("/containers/asdfasdftagged/logs",
            { timestamps: true, stdout: true, stderr: true, follow: true, since: "1538469556.458228203" },
            response_block: instance_of(Mobystash::MobyChunkParser)
          ).ordered.and_raise(Mobystash::MobyEventWorker.const_get(:TerminateEventWorker))

        expect(mock_writer)
          .to receive(:send_event)
          .with(
            message:      "A",
            something:    "funny",
            fred:         "jones",
            nested:       {
              tags: "work",
            },
            moby:         {
              name:     "tagged_container",
              id:       "asdfasdftagged",
              hostname: "tagged-container",
              image:    "rspec/tagged_container:latest",
              image_id: "poiuytrewqtagged",
              stream:   "stdout",
            },
            "@timestamp": "2018-10-02T08:39:16.458228203Z",
            "@metadata":  {
              document_id: match(DOC_ID_REGEX),
              event_type:  "overridden",
            },
          )

        container.run
      end
    end

    context "tty-enabled container" do
      let(:container_name) { "tty_container" }
      let(:container_id)   { "asdfasdftty" }

      before :each do
        allow(mock_moby_container).to receive(:info).and_return("Config" => { "Tty" => true })
      end

      it "asks for a pro-TTY chunk parser" do
        expect(Mobystash::MobyChunkParser).to receive(:new).with(tty: true).and_call_original

        container.run
      end

      it "asks for logs" do
        expect(mock_conn)
          .to receive(:get)
          .with("/containers/asdfasdftty/logs",
            { timestamps: true, stdout: true, stderr: true, follow: true, since: "0.000000000" },
            response_block: instance_of(Mobystash::MobyChunkParser)
          )
          .and_raise(Mobystash::MobyEventWorker.const_get(:TerminateEventWorker))

        container.run
      end
    end

    context "when an error occurs" do
      let(:container_id)   { "asdfasdfbasic" }
      let(:container_name) { "basic_container" }

      before :each do
        expect(Docker::Container)
          .to receive(:get)
          .and_raise(Errno::EBADF)
        expect(Docker::Container)
          .to receive(:get)
          .and_raise(Mobystash::MobyEventWorker.const_get(:TerminateEventWorker))
      end

      it "logs the error" do
        expect_log_message(logger, :error, "Mobystash::Container(asdfasdfbasi)", /EBADF/)

        container.run
      end
    end

    context "when the container goes away" do
      let(:container_id)   { "asdfasdfbasic" }
      let(:container_name) { "basic_container" }

      before :each do
        expect(Docker::Container)
          .to receive(:get).exactly(:once)
          .and_raise(Docker::Error::NotFoundError)
      end

      it "logs the error" do
        expect_log_message(logger, :info, "Mobystash::Container(asdfasdfbasi)", /Container has terminated/)

        container.run
      end
    end
  end
end
