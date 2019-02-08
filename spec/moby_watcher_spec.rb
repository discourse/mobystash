require_relative './spec_helper'

require 'mobystash/config'
require 'mobystash/moby_watcher'

describe Mobystash::MobyWatcher do
  uses_logger

  def test_event(type: "container", action:, id:, time: 987654321)
    actor = Docker::Event::Actor.new(ID: id)

    Docker::Event.new(Type: type, Action: action, id: id, time: time, Actor: actor)
  end

  let(:env) do
    {
      "LOGSTASH_SERVER" => "speccy",
      "DOCKER_HOST" => "unix:///var/run/test.sock"
    }
  end
  let(:config) { Mobystash::Config.new(env, logger: logger) }

  let(:queue)   { Queue.new }
  let(:watcher) { Mobystash::MobyWatcher.new(queue: queue, config: config) }

  describe ".new" do
    it "takes a queue and a docker socket URL" do
      expect(watcher).to be_a(Mobystash::MobyWatcher)
    end
  end

  describe "#run" do
    let(:mock_conn) { instance_double(Docker::Connection) }

    before(:each) do
      allow(Docker::Connection).to receive(:new).with("unix:///var/run/test.sock", read_timeout: 3600).and_return(mock_conn)

      # I'm a bit miffed we have to do this; to my mind, a double should
      # lie a little
      allow(mock_conn).to receive(:is_a?).with(Docker::Connection).and_return(true)
      allow(Docker::Event).to receive(:since).and_raise(Mobystash::MobyEventWorker.const_get(:TerminateEventWorker))

      allow(Time).to receive(:now).and_return(Time.at(1234567890))
    end

    it "connects to the specified socket with a long read timeout" do
      watcher.run

      expect(Docker::Connection).to have_received(:new).with("unix:///var/run/test.sock", read_timeout: 3600)
    end

    it "watches for events since the startup time" do
      expect(Docker::Event).to receive(:since).with(1234567890, {}, mock_conn)

      watcher.run
    end

    it "emits a queue item when a container is created" do
      expect(Docker::Event).to receive(:since).with(1234567890, {}, mock_conn).and_yield(test_event(action: "create", id: "asdfasdfasdf"))

      watcher.run

      expect(queue.length).to eq(1)
      item = queue.pop

      expect(item.first).to eq(:created)
      expect(item.last).to eq("asdfasdfasdf")
    end

    it "emits a queue item when a container is destroyed" do
      expect(Docker::Event).to receive(:since).with(1234567890, {}, mock_conn).and_yield(test_event(action: "destroy", id: "asdfasdfasdf"))

      watcher.run

      expect(queue.length).to eq(1)
      item = queue.pop

      expect(item.first).to eq(:destroyed)
      expect(item.last).to eq("asdfasdfasdf")
    end

    it "ignores uninteresting events" do
      expect(Docker::Event).to receive(:since).with(1234567890, {}, mock_conn).and_yield(test_event(type: "container", action: "spindle", id: "zomg"))

      watcher.run

      expect(queue.length).to eq(0)
    end

    it "continues where it left off after timeout" do
      # This is the first round of Event calls; get an event and then timeout
      expect(Docker::Event).to receive(:since).with(1234567890, {}, mock_conn).and_yield(test_event(action: "create", id: "nope")).and_raise(Docker::Error::TimeoutError)
      # This is the retry, and terminate
      expect(Docker::Event).to receive(:since).with(987654321, {}, mock_conn).and_raise(Mobystash::MobyEventWorker.const_get(:TerminateEventWorker))

      watcher.run
    end

    it "delays then retries on socket error" do
      expect(Docker::Event).to receive(:since).with(1234567890, {}, mock_conn).and_raise(Excon::Error::Socket)
      expect(watcher).to receive(:sleep).with(1)
      expect(Docker::Event).to receive(:since).with(1234567890, {}, mock_conn).and_raise(Mobystash::MobyEventWorker.const_get(:TerminateEventWorker))

      watcher.run
    end

    it "logs and counts unknown exceptions in the event processing loop" do
      expect(Docker::Event).to receive(:since).with(1234567890, {}, mock_conn).and_raise(RuntimeError, "ZOMG")
      expect_log_message(logger, :error, "Mobystash::MobyWatcher(\"unix:///var/run/test.sock\")", /ZOMG/)
      expect(watcher).to receive(:sleep).with(1)
      expect(Docker::Event).to receive(:since).with(1234567890, {}, mock_conn).and_raise(Mobystash::MobyEventWorker.const_get(:TerminateEventWorker))

      watcher.run
    end
  end
end
