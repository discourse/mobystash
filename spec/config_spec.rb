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

    context "MOBYSTASH_SAMPLE_RATIO" do
      let(:value) { config.sample_ratio }

      context "with no value" do
        it "is the default value" do
          expect(value).to eq(1)
        end
      end

      context "with an empty string" do
        let(:env) { base_env.merge("MOBYSTASH_SAMPLE_RATIO" => "") }

        it "is the default value" do
          expect(value).to eq(1)
        end
      end

      context "with an integer" do
        let(:env) { base_env.merge("MOBYSTASH_SAMPLE_RATIO" => "42") }

        it "is the given value" do
          expect(value).to eq(42)
        end
      end

      context "with a float" do
        let(:env) { base_env.merge("MOBYSTASH_SAMPLE_RATIO" => "42.42") }

        it "is the given value" do
          expect(value).to be_within(0.0001).of(42.42)
        end
      end

      context "with zero" do
        let(:env) { base_env.merge("MOBYSTASH_SAMPLE_RATIO" => "0") }

        it "freaks out" do
          expect { config }.to raise_error(Mobystash::Config::InvalidEnvironmentError)
        end
      end

      context "with a negative number" do
        let(:env) { base_env.merge("MOBYSTASH_SAMPLE_RATIO" => "-42") }

        it "freaks out" do
          expect { config }.to raise_error(Mobystash::Config::InvalidEnvironmentError)
        end
      end

      context "with a positive number less than one" do
        let(:env) { base_env.merge("MOBYSTASH_SAMPLE_RATIO" => "0.42") }

        it "freaks out" do
          expect { config }.to raise_error(Mobystash::Config::InvalidEnvironmentError)
        end
      end

      context "with a string" do
        let(:env) { base_env.merge("MOBYSTASH_SAMPLE_RATIO" => "forty-two") }

        it "freaks out" do
          expect { config }.to raise_error(Mobystash::Config::InvalidEnvironmentError)
        end
      end
    end

    context "MOBYSTASH_SAMPLE_KEY_*" do
      let(:sample_keys) { config.sample_keys }

      context "is undefined" do
        it "returns an empty array" do
          expect(sample_keys).to eq([])
        end
      end

      context "a single simple regex" do
        let(:env) { base_env.merge("MOBYSTASH_SAMPLE_KEY_foo" => "abc[de]+") }

        it "returns a single-element array" do
          expect(sample_keys).to eq([[/abc[de]+/, "foo"]])
        end
      end

      context "multiple simple regexes" do
        let(:env) { base_env.merge(
          "MOBYSTASH_SAMPLE_KEY_foo" => "abc[de]+",
          "MOBYSTASH_SAMPLE_KEY_bar" => "lol(rus)?",
        )}

        it "returns a two-element array" do
          expect(sample_keys.length).to eq(2)
          expect(sample_keys).to include([/abc[de]+/, "foo"])
          expect(sample_keys).to include([/lol(rus)?/, "bar"])
        end
      end

      context "capturing regex" do
        let(:env) { base_env.merge("MOBYSTASH_SAMPLE_KEY_cap_\\1_ture" => "the (gr+eat) escape") }

        it "returns a single-element array" do
          expect(sample_keys).to eq([[/the (gr+eat) escape/, "cap_\\1_ture"]])
        end
      end
    end

    context "MOBYSTASH_STATE_FILE" do
      let(:value) { config.state_file }

      context "by default" do
        it "is the default value" do
          expect(value).to eq("./mobystash_state.dump")
        end
      end

      context "with an empty string" do
        let(:env) { base_env.merge("MOBYSTASH_STATE_FILE" => "") }

        it "keeps the default" do
          expect(value).to eq("./mobystash_state.dump")
        end
      end

      context "with a custom value" do
        let(:env) { base_env.merge("MOBYSTASH_STATE_FILE" => "/mobystash/log_positions") }

        it "stores the alternate value" do
          expect(value).to eq('/mobystash/log_positions')
        end
      end
    end

    context "MOBYSTASH_STATE_CHECKPOINT_INTERVAL" do
      let(:value) { config.state_checkpoint_interval }

      context "by default" do
        it "is the default value" do
          expect(value).to eq(1)
        end
      end

      context "with an empty string" do
        let(:env) { base_env.merge("MOBYSTASH_STATE_CHECKPOINT_INTERVAL" => "") }

        it "keeps the default" do
          expect(value).to eq(1)
        end
      end

      context "with an integer" do
        let(:env) { base_env.merge("MOBYSTASH_STATE_CHECKPOINT_INTERVAL" => "42") }

        it "stores the given value" do
          expect(value).to eq(42)
        end
      end

      context "with a decimal number" do
        let(:env) { base_env.merge("MOBYSTASH_STATE_CHECKPOINT_INTERVAL" => "42.42") }

        it "stores the given value" do
          expect(value).to eq(42.42)
        end
      end

      context "with zero" do
        let(:env) { base_env.merge("MOBYSTASH_STATE_CHECKPOINT_INTERVAL" => "0") }

        it "stores the given value" do
          expect(value).to eq(0)
        end
      end

      context "with a negative number" do
        let(:env) { base_env.merge("MOBYSTASH_STATE_CHECKPOINT_INTERVAL" => "-42") }

        it "freaks out" do
          expect { config }.to raise_error(Mobystash::Config::InvalidEnvironmentError)
        end
      end

      context "with a wordy string" do
        let(:env) { base_env.merge("MOBYSTASH_STATE_CHECKPOINT_INTERVAL" => "-forty-two") }

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
