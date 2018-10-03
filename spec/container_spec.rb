require_relative './spec_helper'

require 'mobystash/config'
require 'mobystash/container'

describe Mobystash::Container do
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
        expect(mock_moby_container)
          .to receive(:streaming_logs)
          .with(timestamps: true, stdout: true, stderr: true, follow: true, tty: false, since: "0.000000000")
          .and_raise(Mobystash::MobyEventWorker.const_get(:TerminateEventWorker))

        container.run
      end

      it "forwards logs" do
        expect(mock_moby_container)
          .to receive(:streaming_logs)
          .with(timestamps: true, stdout: true, stderr: true, follow: true, tty: false, since: "0.000000000")
          .and_yield(:stdout, "2018-10-02T08:39:16.458228203Z xyzzy")
          .and_raise(Mobystash::MobyEventWorker.const_get(:TerminateEventWorker))

        expect(mock_writer)
          .to receive(:send_event)
          .with(
            "@timestamp"    => "2018-10-02T08:39:16.458228203Z",
            "moby.name"     => "basic_container",
            "moby.id"       => "asdfasdfbasic",
            "moby.hostname" => "basic-container",
            "moby.image"    => "rspec/basic_container:latest",
            "moby.image_id" => "poiuytrewqbasic",
            "moby.stream"   => "stdout",
            "message"       => "xyzzy",
            "_id"           => match(/\A[A-Za-z0-9+]{22}\z/),
          )

        container.run
      end

      it "asks for new logs next time around" do
        allow(mock_writer).to receive(:send_event)

        expect(mock_moby_container)
          .to receive(:streaming_logs)
          .with(timestamps: true, stdout: true, stderr: true, follow: true, tty: false, since: "0.000000000")
          .and_yield(:stdout, "2009-02-13T23:31:30.987654321Z the first log entry")
        expect(mock_moby_container)
          .to receive(:streaming_logs)
          .with(timestamps: true, stdout: true, stderr: true, follow: true, tty: false, since: "1234567890.987654321")
          .and_raise(Mobystash::MobyEventWorker.const_get(:TerminateEventWorker))

        container.run
      end
    end

    context "mobystash-disabled container" do
      let(:container_name) { "disabled_container" }
      let(:container_id)   { "asdfasdfdisabled" }

      it "does not ask for logs" do
        expect(Docker::Container).to_not receive(:get)
        expect(container).to receive(:sleep).and_raise(Mobystash::MobyEventWorker.const_get(:TerminateEventWorker))

        container.run
      end
    end

    context "mobystash-filtered container" do
      let(:container_name) { "filtered_container" }
      let(:container_id)   { "asdfasdffiltered" }

      it "asks for logs" do
        expect(mock_moby_container)
          .to receive(:streaming_logs)
          .with(timestamps: true, stdout: true, stderr: true, follow: true, tty: false, since: "0.000000000")
          .and_raise(Mobystash::MobyEventWorker.const_get(:TerminateEventWorker))

        container.run
      end

      it "forwards logs not matching the regex" do
        expect(mock_moby_container)
          .to receive(:streaming_logs)
          .with(timestamps: true, stdout: true, stderr: true, follow: true, tty: false, since: "0.000000000")
          .and_yield(:stdout, "2018-10-02T08:39:16.458228203Z A")
          .and_raise(Mobystash::MobyEventWorker.const_get(:TerminateEventWorker))

        expect(mock_writer)
          .to receive(:send_event)
          .with(
            "@timestamp"    => "2018-10-02T08:39:16.458228203Z",
            "moby.name"     => "filtered_container",
            "moby.id"       => "asdfasdffiltered",
            "moby.hostname" => "filtered-container",
            "moby.image"    => "rspec/filtered_container:latest",
            "moby.image_id" => "poiuytrewqfiltered",
            "moby.stream"   => "stdout",
            "message"       => "A",
            "_id"           => match(/\A[A-Za-z0-9+]{22}\z/),
          )

        container.run
      end

      it "doesn't forward logs matching the filter regex" do
        expect(mock_moby_container)
          .to receive(:streaming_logs)
          .with(timestamps: true, stdout: true, stderr: true, follow: true, tty: false, since: "0.000000000")
          .and_yield(:stdout, "2018-10-02T08:39:16.458228203Z Z")
          .and_raise(Mobystash::MobyEventWorker.const_get(:TerminateEventWorker))

        expect(mock_writer).to_not receive(:send_event)

        container.run
      end
    end

    context "mobystash-tagged container" do
      let(:container_name) { "tagged_container" }
      let(:container_id)   { "asdfasdftagged" }

      it "asks for logs" do
        expect(mock_moby_container)
          .to receive(:streaming_logs)
          .with(timestamps: true, stdout: true, stderr: true, follow: true, tty: false, since: "0.000000000")
          .and_raise(Mobystash::MobyEventWorker.const_get(:TerminateEventWorker))

        container.run
      end

      it "sends events with the extra tags" do
        expect(mock_moby_container)
          .to receive(:streaming_logs)
          .with(timestamps: true, stdout: true, stderr: true, follow: true, tty: false, since: "0.000000000")
          .and_yield(:stdout, "2018-10-02T08:39:16.458228203Z A")
          .and_raise(Mobystash::MobyEventWorker.const_get(:TerminateEventWorker))

        expect(mock_writer)
          .to receive(:send_event)
          .with(
            "@timestamp"    => "2018-10-02T08:39:16.458228203Z",
            "moby.name"     => "tagged_container",
            "moby.id"       => "asdfasdftagged",
            "moby.hostname" => "tagged-container",
            "moby.image"    => "rspec/tagged_container:latest",
            "moby.image_id" => "poiuytrewqtagged",
            "moby.stream"   => "stdout",
            "message"       => "A",
            "_type"         => "applog",
            "fred"          => "jones",
            "_id"           => match(/\A[A-Za-z0-9+]{22}\z/),
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

      it "asks for logs" do
        expect(mock_moby_container)
          .to receive(:streaming_logs)
          .with(timestamps: true, stdout: true, stderr: true, follow: true, tty: true, since: "0.000000000")
          .and_raise(Mobystash::MobyEventWorker.const_get(:TerminateEventWorker))

        container.run
      end

      it "handles the deranged argument order" do
        expect(mock_moby_container)
          .to receive(:streaming_logs)
          .with(timestamps: true, stdout: true, stderr: true, follow: true, tty: true, since: "0.000000000")
          .and_yield("2018-10-02T08:39:16.458228203Z tee tee whyyyyyy!", nil)
          .and_raise(Mobystash::MobyEventWorker.const_get(:TerminateEventWorker))

        expect(mock_writer)
          .to receive(:send_event)
          .with(
            "@timestamp"    => "2018-10-02T08:39:16.458228203Z",
            "moby.name"     => "tty_container",
            "moby.id"       => "asdfasdftty",
            "moby.hostname" => "tty-container",
            "moby.image"    => "rspec/tty_container:latest",
            "moby.image_id" => "poiuytrewqtty",
            "moby.stream"   => "tty",
            "message"       => "tee tee whyyyyyy!",
            "_id"           => match(/\A[A-Za-z0-9+]{22}\z/),
          )

        container.run
      end
    end

    context "when everything goes wrong" do
      let(:container_id)   { "asdfasdfbasic" }
      let(:container_name) { "basic_container" }

      before :each do
        expect(Docker::Container)
          .to receive(:get)
          .and_raise(Docker::Error::NotFoundError)
        expect(Docker::Container)
          .to receive(:get)
          .and_raise(Mobystash::MobyEventWorker.const_get(:TerminateEventWorker))
      end

      it "logs the error" do
        expect(logger).to receive(:error).with("Mobystash::Container(asdfasdfbasi)")

        container.run
      end
    end
  end
end
