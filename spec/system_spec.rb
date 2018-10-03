require_relative './spec_helper'

require 'mobystash/system'

describe Mobystash::System do
  uses_logger

  let(:base_env) do
    {
      "LOGSTASH_SERVER" => "speccy",
      "DOCKER_HOST"     => "unix:///var/run/test.sock",
    }
  end
  let(:env) { base_env }

  let(:system) { Mobystash::System.new(env, logger: logger) }

  describe ".new" do
    it "passes the env+logger through to the config" do
      expect(Mobystash::Config).to receive(:new).with(env, logger: logger).and_call_original

      Mobystash::System.new(env, logger: logger)
    end
  end

  describe "#config" do
    it "returns the config" do
      expect(system.config).to be_a(Mobystash::Config)
    end
  end

  let(:mock_queue)   { instance_double(Queue) }
  let(:mock_watcher) { instance_double(Mobystash::MobyWatcher) }
  let(:mock_writer)  { instance_double(LogstashWriter) }

  before(:each) do
    allow(Mobystash::MobyWatcher).to receive(:new).with(queue: mock_queue, config: instance_of(Mobystash::Config)).and_return(mock_watcher)
    allow(LogstashWriter).to receive(:new).with(server_name: "speccy", logger: logger, backlog: 1_000_000, metrics_registry: instance_of(Prometheus::Client::Registry)).and_return(mock_writer)
    allow(mock_writer).to receive(:run)

    allow(Queue).to receive(:new).and_return(mock_queue)
    allow(mock_queue).to receive(:pop).and_return([:terminate])
    allow(mock_watcher).to receive(:run!)
    allow(mock_queue).to receive(:push)
    allow(mock_watcher).to receive(:shutdown!)
    allow(mock_writer).to receive(:stop)
  end

  describe "#shutdown" do
    it "sends the special :terminate message" do
      expect(mock_queue).to receive(:push).with([:terminate])

      system.shutdown
    end
  end
  describe "#run" do
    before(:each) do
      # Stub this out, since run_existing_containers has its own tests
      allow(system).to receive(:run_existing_containers).and_return(nil)
    end

    context "initialization" do
      it "creates a queue" do
        system.run

        expect(Queue).to have_received(:new)
      end

      it "listens on the queue" do
        system.run

        expect(mock_queue).to have_received(:pop)
      end

      it "fires up a docker watcher" do
        system.run

        expect(Mobystash::MobyWatcher).to have_received(:new).with(queue: mock_queue, config: instance_of(Mobystash::Config))
        expect(mock_watcher).to have_received(:run!)
      end

      it "fires up a logstash writer" do
        system.run

        expect(LogstashWriter).to have_received(:new)
        expect(mock_writer).to have_received(:run)
      end

      it "creates and starts existing logging for existing containers" do
        expect(system).to receive(:run_existing_containers)

        system.run
      end

      context "if enable_metrics is true" do
        let(:env) { base_env.merge("MOBYSTASH_ENABLE_METRICS" => "yes") }
        let(:mock_metrics_server) { instance_double(Frankenstein::Server) }

        before(:each) do
          allow(mock_metrics_server).to receive(:shutdown)
        end

        it "fires up the metrics server" do
          expect(Frankenstein::Server).to receive(:new).with(port: 9367, logger: logger, registry: instance_of(Prometheus::Client::Registry)).and_return(mock_metrics_server)
          expect(mock_metrics_server).to receive(:run)

          system.run
        end
      end
    end

    describe "processing message" do
      let(:mock_conn) { instance_double(Docker::Connection) }
      let(:docker_data) { container_fixture("basic_container") }
      let(:mobystash_container) { instance_double(Mobystash::Container) }

      before(:each) do
        # This one's for the container_fixture calls
        allow(Docker::Connection).to receive(:new).with("unix:///", {}).and_call_original
        # This is the real one
        allow(Docker::Connection).to receive(:new).with("unix:///var/run/test.sock", {}).and_return(mock_conn)

        allow(Docker::Container).to receive(:get).with("asdfasdfbasic", {}, mock_conn).and_return(docker_data)
        allow(Mobystash::Container).to receive(:new).with(docker_data, system.config).and_return(mobystash_container)
        allow(mobystash_container).to receive(:shutdown!)
      end

      describe ":created" do
        it "tells the container to go publish itself" do
          expect(mock_queue).to receive(:pop).and_return([:created, "asdfasdfbasic"])
          expect(Docker::Container).to receive(:get).with("asdfasdfbasic", {}, mock_conn).and_return(docker_data)
          expect(Mobystash::Container).to receive(:new).with(docker_data, system.config).and_return(mobystash_container)
          expect(mobystash_container).to receive(:run!)

          system.run

          expect(system.instance_variable_get(:@containers).values).to eq([mobystash_container])
        end

        it "handles things smoothly if the container already exists" do
          c1 = instance_double(Mobystash::Container)
          allow(c1).to receive(:shutdown!)
          system.instance_variable_set(:@containers, "c1" => c1)

          expect(mock_queue).to receive(:pop).and_return([:created, "c1"])
          expect(Mobystash::Container).to_not receive(:new)

          system.run

          expect(system.instance_variable_get(:@containers)).to eq("c1" => c1)
        end

        it "does not explode if the created container disappears before the get" do
          expect(mock_queue).to receive(:pop).and_return([:created, "c1"])
          expect(Docker::Container).to receive(:get).and_raise(Docker::Error::NotFoundError)
          expect(Mobystash::Container).to_not receive(:new)
          expect(logger).to_not receive(:error)

          system.run

          expect(system.instance_variable_get(:@containers)).to eq({})
        end
      end

      describe ":destroyed" do
        it "shuts down the container if it exists" do
          system.instance_variable_get(:@containers)["asdfasdfbasic"] = mobystash_container

          expect(mock_queue).to receive(:pop).and_return([:destroyed, "asdfasdfbasic"])

          system.run

          expect(mobystash_container).to have_received(:shutdown!)
        end

        it "is OK if the container doesn't exist" do
          expect(mock_queue).to receive(:pop).and_return([:destroyed, "asdfasdfbasic"])
          expect(mobystash_container).to_not receive(:shutdown!)

          system.run
        end
      end

      describe ":terminate" do
        before :each do
          expect(mock_queue).to receive(:pop).and_return([:terminate])
        end

        it "tells the watcher to shutdown" do
          expect(mock_watcher).to receive(:shutdown!)

          system.run
        end

        it "tells the writer to shutdown" do
          expect(mock_writer).to receive(:stop)

          system.run
        end

        it "tells the containers to shutdown" do
          c1 = instance_double(Mobystash::Container)
          c2 = instance_double(Mobystash::Container)

          system.instance_variable_set(:@containers, "c1" => c1, "c2" => c2)

          expect(c1).to receive(:shutdown!)
          expect(c2).to receive(:shutdown!)

          system.run
        end
      end
    end

    describe "unknown message" do
      it "logs an error" do
        expect(mock_queue).to receive(:pop).and_return("whaddya mean this ain't a valid message?!?")

        expect(logger).to receive(:error)

        system.run
      end
    end
  end

  describe "#run_existing_containers" do
    let(:mock_conn) { instance_double(Docker::Connection) }

    before(:each) do
      # This one's for the container_fixture calls
      allow(Docker::Connection).to receive(:new).with("unix:///", {}).and_call_original
      # This is the real one
      allow(Docker::Connection).to receive(:new).with("unix:///var/run/test.sock", {}).and_return(mock_conn)

      allow(Docker::Container).to receive(:all).with({}, mock_conn).and_return([])
      allow(Docker::Container).to receive(:get).with("asdfasdfbasic", {}, mock_conn).and_return(container_fixture("basic_container"))
      allow(Docker::Container).to receive(:get).with("asdfasdfdisabled", {}, mock_conn).and_return(container_fixture("disabled_container"))
    end

    it "requests a current container list" do
      system.send(:run_existing_containers)

      expect(Docker::Container).to have_received(:all).with({}, mock_conn)
    end

    it "runs the containers it finds" do
      moby_container = container_fixture("basic_container")
      expect(Docker::Container).to receive(:all).with({}, mock_conn).and_return([moby_container])
      expect(Docker::Container).to receive(:get).with("asdfasdfbasic", {}, mock_conn).and_return(moby_container)

      expect(Mobystash::Container).to receive(:new).with(moby_container, system.config).and_return(mobystash_container = instance_double(Mobystash::Container))
      expect(mobystash_container).to receive(:run!)

      system.send(:run_existing_containers)
    end

    it "doesn't include containers that disappear between the all and the get" do
      expect(Docker::Container).to receive(:all).with({}, mock_conn).and_return(container_fixtures("basic_container", "filtered_container", "disabled_container"))
      expect(Docker::Container).to receive(:get).with("asdfasdfbasic", {}, mock_conn)
      expect(Docker::Container).to receive(:get).with("asdfasdffiltered", {}, mock_conn).and_raise(Docker::Error::NotFoundError)
      expect(Docker::Container).to receive(:get).with("asdfasdfdisabled", {}, mock_conn)

      system.send(:run_existing_containers)

      expect(system.instance_variable_get(:@containers).keys.sort).to eq(["asdfasdfbasic", "asdfasdfdisabled"])
    end
  end
end
