require_relative './spec_helper'

require 'mobystash/container'

describe Mobystash::Container do
  DOC_ID_REGEX = /\A[A-Za-z0-9+\/]{22}\z/.freeze

  uses_logger

  let(:env) do
    {
      "LOGSTASH_SERVER" => "speccy",
    }
  end

  let(:mock_metrics)        { MockMetrics.new }
  let(:mock_writer)         { instance_double(LogstashWriter) }
  let(:mock_config)         { MockConfig.new(logger) }
  let(:sampler)             { Mobystash::Sampler.new(mock_config, mock_metrics) }
  let(:docker_data)         { container_fixture(container_name) }
  let(:last_log_time)       { nil }
  let(:container)           { Mobystash::Container.new(docker_data, mock_config, last_log_time: last_log_time, sampler: sampler, metrics: mock_metrics, writer: mock_writer) }
  let(:mock_conn)           { instance_double(Docker::Connection) }
  let(:mock_moby_container) { instance_double(Docker::Container) }

  before :each do
    allow(LogstashWriter).to receive(:new).with(
      server_name: "speccy",
      logger: logger,
      metrics_registry: instance_of(Prometheus::Client::Registry),
      backlog: 1_000_000
    ).and_return(mock_writer)
    allow(Docker::Connection).to receive(:new).with("unix:///", {}).and_call_original
  end

  describe ".new" do
    context "basic container" do
      let(:container_name) { "basic_container" }

      it "creates the container object" do
        expect(container).to be_a(Mobystash::Container)
      end

      it "uses the default last_log_timestamp" do
        expect(container.last_log_timestamp).to eq("1970-01-01T00:00:00.000000000Z")
      end
    end

    context "with a last_log_time" do
      let(:container_name) { "basic_container" }
      let(:last_log_time)  { Time.at(1244019963 + Rational(987_654_321, 1_000_000_000)).utc }

      it "overrides the last_log_timestamp" do
        expect(container.last_log_timestamp).to eq("2009-06-03T09:06:03.987654321Z")
      end
    end
  end

  describe "#run" do
    before(:each) do
      allow(Docker::Connection).to receive(:new).with("unix:///var/run/test.sock", read_timeout: 3600).and_return(mock_conn)
      allow(mock_conn).to receive(:get).and_raise(Mobystash::MobyEventWorker.const_get(:TerminateEventWorker))
      allow(Docker::Container).to receive(:new).with(instance_of(Docker::Connection), instance_of(Hash)).and_call_original
      allow(Docker::Container).to receive(:get).with(container_id, {}, mock_conn).and_return(mock_moby_container)
      allow(mock_moby_container).to receive(:info).and_return("Config" => { "Tty" => false }, "State" => { "Status" => "running" })

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
            { timestamps: true, stdout: true, stderr: true, follow: true, since: "0.000000001" },
            idempotent: false,
            response_block: instance_of(Mobystash::MobyChunkParser)
          )
          .and_raise(Mobystash::MobyEventWorker.const_get(:TerminateEventWorker))

        container.run
      end

      it "forwards logs" do
        expect(mock_conn)
          .to receive(:get) do |path, opts, excon_opts|
            expect(path).to eq("/containers/asdfasdfbasic/logs")
            expect(opts).to eq(timestamps: true, stdout: true, stderr: true, follow: true, since: "0.000000001")
            expect(excon_opts).to have_key(:response_block)
            expect(excon_opts[:response_block]).to be_a(Mobystash::MobyChunkParser)
            expect(excon_opts[:idempotent]).to be(false)

            excon_opts[:response_block].call("\x01\x00\x00\x00\x00\x00\x00$2018-10-02T08:39:16.458228203Z xyzzy", 0, 0)
          end.ordered.and_return(nil)
        expect(mock_conn)
          .to receive(:get)
          .with("/containers/asdfasdfbasic/logs",
            { timestamps: true, stdout: true, stderr: true, follow: true, since: "1538469556.458228204" },
            idempotent: false,
            response_block: instance_of(Mobystash::MobyChunkParser)
          )
          .and_raise(Mobystash::MobyEventWorker.const_get(:TerminateEventWorker))

        expect(mock_writer)
          .to receive(:send_event)
          .with(
            message: "xyzzy",
            container: {
              id: "asdfasdfbasic",
              image: {
                name: "rspec/basic_container:latest",
                id: "poiuytrewqbasic",
              },
              name: "basic_container",
              hostname: "basic-container",
            },
            ecs: {
              version: '1.8',
            },
            labels: {
              stream: "stdout",
            },
            "@timestamp": "2018-10-02T08:39:16.458228203Z",
            "@metadata": {
              document_id: match(DOC_ID_REGEX),
              event_type: "moby",
            },
          )

        container.run
      end

      it "asks for new logs next time around" do
        allow(mock_writer).to receive(:send_event)

        expect(mock_conn)
          .to receive(:get) do |path, opts, excon_opts|
            expect(path).to eq("/containers/asdfasdfbasic/logs")
            expect(opts).to eq(timestamps: true, stdout: true, stderr: true, follow: true, since: "0.000000001")
            expect(excon_opts).to have_key(:response_block)
            expect(excon_opts[:response_block]).to be_a(Mobystash::MobyChunkParser)
            expect(excon_opts[:idempotent]).to be(false)

            excon_opts[:response_block].call("\x01\x00\x00\x00\x00\x00\x00 2009-02-13T23:31:30.987654321Z A", 0, 0)
          end.ordered.and_return(nil)
        expect(mock_conn)
          .to receive(:get)
          .with("/containers/asdfasdfbasic/logs",
            { timestamps: true, stdout: true, stderr: true, follow: true, since: "1234567890.987654322" },
            idempotent: false,
            response_block: instance_of(Mobystash::MobyChunkParser)
          )
          .and_raise(Mobystash::MobyEventWorker.const_get(:TerminateEventWorker))

        container.run
      end

      it "takes no notice of 'syslog style' messages" do
        expect(mock_conn)
          .to receive(:get) do |path, opts, excon_opts|
            expect(path).to eq("/containers/asdfasdfbasic/logs")
            expect(opts).to eq(timestamps: true, stdout: true, stderr: true, follow: true, since: "0.000000001")
            expect(excon_opts).to have_key(:response_block)
            expect(excon_opts[:response_block]).to be_a(Mobystash::MobyChunkParser)
            expect(excon_opts[:idempotent]).to be(false)

            excon_opts[:response_block].call("\x02\x00\x00\x00\x00\x00\x00Z2018-10-02T08:39:16.458228203Z <150>Oct 11 10:10:35 sumhost ohai[3656]: hello from syslog!", 0, 0)
          end.exactly(:once)
        expect(mock_conn)
          .to receive(:get)
          .with("/containers/asdfasdfbasic/logs",
            { timestamps: true, stdout: true, stderr: true, follow: true, since: "1538469556.458228204" },
            idempotent: false,
            response_block: instance_of(Mobystash::MobyChunkParser)
          )
          .and_raise(Mobystash::MobyEventWorker.const_get(:TerminateEventWorker))

        expect(mock_writer)
          .to receive(:send_event)
          .with(
            message: "<150>Oct 11 10:10:35 sumhost ohai[3656]: hello from syslog!",
            container: {
              id: "asdfasdfbasic",
              image: {
                name: "rspec/basic_container:latest",
                id: "poiuytrewqbasic",
              },
              name: "basic_container",
              hostname: "basic-container",
            },
            ecs: {
              version: '1.8',
            },
            labels: {
              stream: "stderr",
            },
            "@timestamp": "2018-10-02T08:39:16.458228203Z",
            "@metadata": {
              document_id: match(DOC_ID_REGEX),
              event_type: "moby",
            },
          )

        container.run
      end
    end

    context "mobystash-disabled container" do
      let(:container_name) { "disabled_container" }
      let(:container_id)   { "asdfasdfdisabled" }

      it "does not ask for logs" do
        allow(Docker::Container).to receive(:get).and_return(Struct.new(:info).new("Config" => {}, "State" => { "Status" => "running" }))
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
            { timestamps: true, stdout: true, stderr: true, follow: true, since: "0.000000001" },
            idempotent: false,
            response_block: instance_of(Mobystash::MobyChunkParser)
          )
          .and_raise(Mobystash::MobyEventWorker.const_get(:TerminateEventWorker))

        container.run
      end

      it "forwards logs not matching the regex" do
        expect(mock_conn)
          .to receive(:get) do |path, opts, excon_opts|
            expect(path).to eq("/containers/asdfasdffiltered/logs")
            expect(opts).to eq(timestamps: true, stdout: true, stderr: true, follow: true, since: "0.000000001")
            expect(excon_opts).to have_key(:response_block)
            expect(excon_opts[:response_block]).to be_a(Mobystash::MobyChunkParser)
            expect(excon_opts[:idempotent]).to be(false)

            excon_opts[:response_block].call("\x01\x00\x00\x00\x00\x00\x00 2018-10-02T08:39:16.458228203Z A", 0, 0)
          end.ordered.and_return(nil)
        expect(mock_conn)
          .to receive(:get)
          .with("/containers/asdfasdffiltered/logs",
            { timestamps: true, stdout: true, stderr: true, follow: true, since: "1538469556.458228204" },
            idempotent: false,
            response_block: instance_of(Mobystash::MobyChunkParser)
          )
          .and_raise(Mobystash::MobyEventWorker.const_get(:TerminateEventWorker))

        expect(mock_writer)
          .to receive(:send_event)
          .with(
            message: "A",
            container: {
              id: "asdfasdffiltered",
              image: {
                name: "rspec/filtered_container:latest",
                id: "poiuytrewqfiltered",
              },
              name: "filtered_container",
              hostname: "filtered-container",
            },
            ecs: {
              version: '1.8',
            },
            labels: {
              stream: "stdout",
            },
            "@timestamp": "2018-10-02T08:39:16.458228203Z",
            "@metadata": {
              document_id: match(DOC_ID_REGEX),
              event_type: "moby",
            },
          )

        container.run
      end

      it "doesn't forward logs matching the filter regex" do
        expect(mock_conn)
          .to receive(:get) do |path, opts, excon_opts|
            expect(path).to eq("/containers/asdfasdffiltered/logs")
            expect(opts).to eq(timestamps: true, stdout: true, stderr: true, follow: true, since: "0.000000001")
            expect(excon_opts).to have_key(:response_block)
            expect(excon_opts[:response_block]).to be_a(Mobystash::MobyChunkParser)
            expect(excon_opts[:idempotent]).to be(false)

            excon_opts[:response_block].call("\x01\x00\x00\x00\x00\x00\x00 2018-10-02T08:39:16.458228203Z Z", 0, 0)
          end.ordered.and_return(nil)
        expect(mock_conn)
          .to receive(:get)
          .with("/containers/asdfasdffiltered/logs",
            { timestamps: true, stdout: true, stderr: true, follow: true, since: "1538469556.458228204" },
            idempotent: false,
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
            { timestamps: true, stdout: true, stderr: true, follow: true, since: "0.000000001" },
            idempotent: false,
            response_block: instance_of(Mobystash::MobyChunkParser)
          ).and_raise(Mobystash::MobyEventWorker.const_get(:TerminateEventWorker))

        container.run
      end

      it "sends events with the extra tags" do
        expect(mock_conn)
          .to receive(:get) do |path, opts, excon_opts|
            expect(path).to eq("/containers/asdfasdftagged/logs")
            expect(opts).to eq(timestamps: true, stdout: true, stderr: true, follow: true, since: "0.000000001")
            expect(excon_opts).to have_key(:response_block)
            expect(excon_opts[:response_block]).to be_a(Mobystash::MobyChunkParser)
            expect(excon_opts[:idempotent]).to be(false)

            excon_opts[:response_block].call("\x01\x00\x00\x00\x00\x00\x00 2018-10-02T08:39:16.458228203Z A", 0, 0)
          end.ordered.and_return(nil)
        expect(mock_conn)
          .to receive(:get)
          .with("/containers/asdfasdftagged/logs",
            { timestamps: true, stdout: true, stderr: true, follow: true, since: "1538469556.458228204" },
            idempotent: false,
            response_block: instance_of(Mobystash::MobyChunkParser)
          ).ordered.and_raise(Mobystash::MobyEventWorker.const_get(:TerminateEventWorker))

        expect(mock_writer)
          .to receive(:send_event)
          .with(
            message: "A",
            something: "funny",
            fred: "jones",
            nested: {
              tags: "work",
            },
            container: {
              id: "asdfasdftagged",
              image: {
                name: "rspec/tagged_container:latest",
                id: "poiuytrewqtagged",
              },
              name: "tagged_container",
              hostname: "tagged-container",
            },
            ecs: {
              version: '1.8',
            },
            labels: {
              stream: "stdout",
            },
            "@timestamp": "2018-10-02T08:39:16.458228203Z",
            "@metadata": {
              document_id: match(DOC_ID_REGEX),
              event_type: "overridden",
            },
          )

        container.run
      end
    end

    context "tty-enabled container" do
      let(:container_name) { "tty_container" }
      let(:container_id)   { "asdfasdftty" }

      before :each do
        allow(mock_moby_container).to receive(:info).and_return("Config" => { "Tty" => true }, "State" => { "Status" => "running" })
      end

      it "asks for a pro-TTY chunk parser" do
        expect(Mobystash::MobyChunkParser).to receive(:new).with(tty: true).and_call_original

        container.run
      end

      it "asks for logs" do
        expect(mock_conn)
          .to receive(:get)
          .with("/containers/asdfasdftty/logs",
            { timestamps: true, stdout: true, stderr: true, follow: true, since: "0.000000001" },
            idempotent: false,
            response_block: instance_of(Mobystash::MobyChunkParser)
          )
          .and_raise(Mobystash::MobyEventWorker.const_get(:TerminateEventWorker))

        container.run
      end
    end

    context "syslog-enabled container" do
      let(:container_name) { "syslog_container" }
      let(:container_id)   { "asdfasdfsyslog" }

      it "relays non-syslog entries without modification" do
        expect(mock_conn)
          .to receive(:get) do |path, opts, excon_opts|
            expect(path).to eq("/containers/asdfasdfsyslog/logs")
            expect(opts).to eq(timestamps: true, stdout: true, stderr: true, follow: true, since: "0.000000001")
            expect(excon_opts).to have_key(:response_block)
            expect(excon_opts[:response_block]).to be_a(Mobystash::MobyChunkParser)
            expect(excon_opts[:idempotent]).to be(false)

            excon_opts[:response_block].call("\x02\x00\x00\x00\x00\x00\x00 2018-10-02T08:39:16.458228203Z A", 0, 0)
          end.ordered.and_return(nil)
        expect(mock_conn)
          .to receive(:get)
          .with("/containers/asdfasdfsyslog/logs",
            { timestamps: true, stdout: true, stderr: true, follow: true, since: "1538469556.458228204" },
            idempotent: false,
            response_block: instance_of(Mobystash::MobyChunkParser)
          )
          .and_raise(Mobystash::MobyEventWorker.const_get(:TerminateEventWorker))

        expect(mock_writer)
          .to receive(:send_event)
          .with(
            message: "A",
            container: {
              id: "asdfasdfsyslog",
              image: {
                name: "rspec/syslog_container:latest",
                id: "poiuytrewqsyslog",
              },
              name: "syslog_container",
              hostname: "syslog-container",
            },
            ecs: {
              version: '1.8',
            },
            labels: {
              stream: "stderr",
            },
            "@timestamp": "2018-10-02T08:39:16.458228203Z",
            "@metadata": {
              document_id: match(DOC_ID_REGEX),
              event_type: "moby",
            },
          )

        container.run
      end

      it "relays syslog entries with syslog tags" do
        expect(mock_conn)
          .to receive(:get) do |path, opts, excon_opts|
            expect(path).to eq("/containers/asdfasdfsyslog/logs")
            expect(opts).to eq(timestamps: true, stdout: true, stderr: true, follow: true, since: "0.000000001")
            expect(excon_opts).to have_key(:response_block)
            expect(excon_opts[:response_block]).to be_a(Mobystash::MobyChunkParser)
            expect(excon_opts[:idempotent]).to be(false)

            excon_opts[:response_block].call("\x02\x00\x00\x00\x00\x00\x00Z2018-10-02T08:39:16.458228203Z <150>Oct 11 10:10:35 sumhost ohai[3656]: hello from syslog!", 0, 0)
          end.ordered.and_return(nil)
        expect(mock_conn)
          .to receive(:get)
          .with("/containers/asdfasdfsyslog/logs",
            { timestamps: true, stdout: true, stderr: true, follow: true, since: "1538469556.458228204" },
            idempotent: false,
            response_block: instance_of(Mobystash::MobyChunkParser)
          )
          .and_raise(Mobystash::MobyEventWorker.const_get(:TerminateEventWorker))

        expect(mock_writer)
          .to receive(:send_event)
          .with(
            message: "hello from syslog!",
            container: {
              id: "asdfasdfsyslog",
              image: {
                name: "rspec/syslog_container:latest",
                id: "poiuytrewqsyslog",
              },
              name: "syslog_container",
              hostname: "syslog-container",
            },
            ecs: {
              version: '1.8',
            },
            event: {
              created: "2018-10-02T08:39:16.458228203Z"
            },
            host: {
              hostname: "sumhost",
            },
            labels: {
              stream: "stderr",
            },
            log: {
              original: "<150>Oct 11 10:10:35 sumhost ohai[3656]: hello from syslog!",
              syslog: {
                facility: {
                  code: 18,
                  name: "local2",
                },
                severity: {
                  code: 6,
                  name: "info",
                },
              },
            },
            process: {
              name: 'ohai',
              pid: 3656,
            },
            "@timestamp": "2021-10-11T10:10:35.000Z",
            "@metadata": {
              document_id: match(DOC_ID_REGEX),
              event_type: "moby",
            },
          )
        container.run
      end

      it "relays syslog entries with syslog tags and no program name" do
        expect(mock_conn)
          .to receive(:get) do |path, opts, excon_opts|
            expect(path).to eq("/containers/asdfasdfsyslog/logs")
            expect(opts).to eq(timestamps: true, stdout: true, stderr: true, follow: true, since: "0.000000001")
            expect(excon_opts).to have_key(:response_block)
            expect(excon_opts[:response_block]).to be_a(Mobystash::MobyChunkParser)
            expect(excon_opts[:idempotent]).to be(false)

            excon_opts[:response_block].call("\x02\x00\x00\x00\x00\x00\x00N2018-10-02T08:39:16.458228203Z <150>Oct 11 10:10:35 sumhost hello from syslog!", 0, 0)
          end.ordered.and_return(nil)
        expect(mock_conn)
          .to receive(:get)
          .with("/containers/asdfasdfsyslog/logs",
            { timestamps: true, stdout: true, stderr: true, follow: true, since: "1538469556.458228204" },
            idempotent: false,
            response_block: instance_of(Mobystash::MobyChunkParser)
          )
          .and_raise(Mobystash::MobyEventWorker.const_get(:TerminateEventWorker))

        expect(mock_writer)
          .to receive(:send_event)
          .with(
            message: "hello from syslog!",
            container: {
              id: "asdfasdfsyslog",
              image: {
                name: "rspec/syslog_container:latest",
                id: "poiuytrewqsyslog",
              },
              name: "syslog_container",
              hostname: "syslog-container",
            },
            ecs: {
              version: '1.8',
            },
            event: {
              created: "2018-10-02T08:39:16.458228203Z"
            },
            host: {
              hostname: "sumhost",
            },
            labels: {
              stream: "stderr",
            },
            log: {
              original: "<150>Oct 11 10:10:35 sumhost hello from syslog!",
              syslog: {
                facility: {
                  code: 18,
                  name: "local2",
                },
                severity: {
                  code: 6,
                  name: "info",
                },
              },
            },
            "@timestamp": "2021-10-11T10:10:35.000Z",
            "@metadata": {
              document_id: match(DOC_ID_REGEX),
              event_type: "moby",
            },
          )

        container.run
      end

      it "relays syslog entries with syslog tags and no hostname or pid" do
        expect(mock_conn)
          .to receive(:get) do |path, opts, excon_opts|
            expect(path).to eq("/containers/asdfasdfsyslog/logs")
            expect(opts).to eq(timestamps: true, stdout: true, stderr: true, follow: true, since: "0.000000001")
            expect(excon_opts).to have_key(:response_block)
            expect(excon_opts[:response_block]).to be_a(Mobystash::MobyChunkParser)
            expect(excon_opts[:idempotent]).to be(false)

            excon_opts[:response_block].call("\x02\x00\x00\x00\x00\x00\x00L2018-10-02T08:39:16.458228203Z <150>Oct 11 10:10:35 ohai: hello from syslog!", 0, 0)
          end.ordered.and_return(nil)
        expect(mock_conn)
          .to receive(:get)
          .with("/containers/asdfasdfsyslog/logs",
            { timestamps: true, stdout: true, stderr: true, follow: true, since: "1538469556.458228204" },
            idempotent: false,
            response_block: instance_of(Mobystash::MobyChunkParser)
          )
          .and_raise(Mobystash::MobyEventWorker.const_get(:TerminateEventWorker))

        expect(mock_writer)
          .to receive(:send_event)
          .with(
            message: "hello from syslog!",
            container: {
              id: "asdfasdfsyslog",
              image: {
                name: "rspec/syslog_container:latest",
                id: "poiuytrewqsyslog",
              },
              name: "syslog_container",
              hostname: "syslog-container",
            },
            ecs: {
              version: '1.8',
            },
            event: {
              created: "2018-10-02T08:39:16.458228203Z"
            },
            labels: {
              stream: "stderr",
            },
            process: {
              name: 'ohai',
            },
            log: {
              original: "<150>Oct 11 10:10:35 ohai: hello from syslog!",
              syslog: {
                facility: {
                  code: 18,
                  name: "local2",
                },
                severity: {
                  code: 6,
                  name: "info",
                },
              },
            },
            "@timestamp": "2021-10-11T10:10:35.000Z",
            "@metadata": {
              document_id: match(DOC_ID_REGEX),
              event_type: "moby",
            },
          )

        container.run
      end

      it "relays syslog entries with syslog tags but no recognisable form" do
        expect(mock_conn)
          .to receive(:get) do |path, opts, excon_opts|
            expect(path).to eq("/containers/asdfasdfsyslog/logs")
            expect(opts).to eq(timestamps: true, stdout: true, stderr: true, follow: true, since: "0.000000001")
            expect(excon_opts).to have_key(:response_block)
            expect(excon_opts[:response_block]).to be_a(Mobystash::MobyChunkParser)
            expect(excon_opts[:idempotent]).to be(false)

            excon_opts[:response_block].call("\x02\x00\x00\x00\x00\x00\x00D2018-10-02T08:39:16.458228203Z <150>Oct 11 10:10:35 hellofromsyslog!", 0, 0)
          end.ordered.and_return(nil)
        expect(mock_conn)
          .to receive(:get)
          .with("/containers/asdfasdfsyslog/logs",
            { timestamps: true, stdout: true, stderr: true, follow: true, since: "1538469556.458228204" },
            idempotent: false,
            response_block: instance_of(Mobystash::MobyChunkParser)
          )
          .and_raise(Mobystash::MobyEventWorker.const_get(:TerminateEventWorker))

        expect(mock_writer)
          .to receive(:send_event)
          .with(
            message: "hellofromsyslog!",
            container: {
              id: "asdfasdfsyslog",
              image: {
                name: "rspec/syslog_container:latest",
                id: "poiuytrewqsyslog",
              },
              name: "syslog_container",
              hostname: "syslog-container",
            },
            ecs: {
              version: '1.8',
            },
            event: {
              created: "2018-10-02T08:39:16.458228203Z"
            },
            labels: {
              stream: "stderr",
            },
            log: {
              original: "<150>Oct 11 10:10:35 hellofromsyslog!",
              syslog: {
                facility: {
                  code: 18,
                  name: "local2",
                },
                severity: {
                  code: 6,
                  name: "info",
                },
              },
            },
            "@timestamp": "2021-10-11T10:10:35.000Z",
            "@metadata": {
              document_id: match(DOC_ID_REGEX),
              event_type: "moby",
            },
          )

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

  describe "#last_log_timestamp" do
    let(:container_name)      { "basic_container" }
    let(:container_id)        { "asdfasdfbasic" }

    before(:each) do
      allow(Docker::Connection).to receive(:new).with("unix:///var/run/test.sock", read_timeout: 3600).and_return(mock_conn)
      allow(Docker::Container).to receive(:new).with(instance_of(Docker::Connection), instance_of(Hash)).and_call_original
      allow(Docker::Container).to receive(:get).with(container_id, {}, mock_conn).and_return(mock_moby_container)
      allow(mock_moby_container).to receive(:info).and_return("Config" => { "Tty" => false }, "State" => { "Status" => "running" })

      # I'm a bit miffed we have to do this; to my mind, a double should
      # lie a little
      allow(mock_conn).to receive(:is_a?).with(Docker::Connection).and_return(true)
    end

    it "returns time zero at first" do
      expect(container.last_log_timestamp).to eq("1970-01-01T00:00:00.000000000Z")
    end

    it "returns the last log timestamp" do
      allow(mock_writer).to receive(:send_event)

      expect(mock_conn)
        .to receive(:get) do |_path, _opts, excon_opts|
          excon_opts[:response_block].call("\x01\x00\x00\x00\x00\x00\x00 2009-02-13T23:31:30.987654321Z A", 0, 0)
        end.ordered.and_return(nil)
      expect(mock_conn)
        .to receive(:get)
        .and_raise(Mobystash::MobyEventWorker.const_get(:TerminateEventWorker))

      container.run

      expect(container.last_log_timestamp).to eq("2009-02-13T23:31:30.987654321Z")
    end
  end
end
