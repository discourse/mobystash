require_relative './spec_helper'

require 'mobystash/config'

describe Mobystash::Config do
  uses_logger

  let(:base_env) do
    {
      "LOGSTASH_SERVER" => "192.0.2.42:5151",
    }
  end
  # Work around problem where you can't reference the same let in a nested
  # scope any more without ending up in a recursive hellscape.
  let(:env) { base_env }

  let(:config) { Mobystash::Config.new(env, logger: logger) }

  describe ".new" do
    it "creates a config object" do
      expect(config).to be_a(Mobystash::Config)
    end

    it "accepts our logger" do
      expect(config.logger).to eq(logger)
    end

    context "LOGSTASH_SERVER" do
      it "freaks out without it" do
        expect { Mobystash::Config.new(env.reject { |k| k == "LOGSTASH_SERVER" }, logger: logger) }.to raise_error(Mobystash::Config::InvalidEnvironmentError)
      end

      it "freaks out if it's empty" do
        expect { Mobystash::Config.new(env.merge("LOGSTASH_SERVER" => ""), logger: logger) }.to raise_error(Mobystash::Config::InvalidEnvironmentError)
      end

      it "is OK with something validish" do
        expect(config.logstash_writer).to be_a(LogstashWriter)
      end
    end

    context "MOBYSTASH_ENABLE_METRICS" do
      let(:value) { config.enable_metrics }

      context "with an empty string" do
        let(:env) { base_env.merge("MOBYSTASH_ENABLE_METRICS" => "") }

        it "is false" do
          expect(value).to eq(false)
        end
      end

      %w{on yes 1 true}.each do |s|
        context "with true-ish value #{s}" do
          let(:env) { base_env.merge("MOBYSTASH_ENABLE_METRICS" => s) }

          it "is true" do
            expect(value).to eq(true)
          end
        end
      end

      %w{off no 0 false}.each do |s|
        context "with false-y value #{s}" do
          let(:env) { base_env.merge("MOBYSTASH_ENABLE_METRICS" => s) }

          it "is false" do
            expect(value).to eq(false)
          end
        end
      end

      context "with other values" do
        let(:env) { base_env.merge("MOBYSTASH_ENABLE_METRICS" => "ermahgerd") }

        it "freaks out" do
          expect { config }.to raise_error(Mobystash::Config::InvalidEnvironmentError)
        end
      end
    end

    context "DOCKER_HOST" do
      let(:value) { config.docker_host }

      context "with an empty string" do
        let(:env) { base_env.merge("DOCKER_HOST" => "") }

        it "keeps the default" do
          expect(config.docker_host).to eq("unix:///var/run/docker.sock")
        end
      end

      context "with a custom value" do
        let(:env) { base_env.merge("DOCKER_HOST" => "tcp://192.0.2.42") }

        it "stores the alternate value" do
          expect(config.docker_host).to eq('tcp://192.0.2.42')
        end
      end
    end
  end
end
