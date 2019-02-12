require_relative './spec_helper'

require 'mobystash/config'
require 'mobystash/sampler'

describe Mobystash::Sampler do
  uses_logger

  let(:sampler) { Mobystash::Sampler.new(mock_config) }

  let(:mock_config)     { instance_double(Mobystash::Config) }
  let(:sample_ratio)    { 10 }
  let(:sample_keys)     { [] }
  let(:unsampled)       { instance_double(PrometheusExporter::Metric::Counter, "unsampled") }
  let(:samples_sent)    { instance_double(PrometheusExporter::Metric::Counter, "samples_sent") }
  let(:samples_dropped) { instance_double(PrometheusExporter::Metric::Counter, "samples_dropped") }
  let(:sample_ratios)   { instance_double(PrometheusExporter::Metric::Gauge, "sample_ratios") }
  let(:sent_values)     { {} }
  let(:dropped_values)  { {} }
  let(:ratio_values)    { {} }

  before(:each) do
    allow(mock_config).to receive(:sample_ratio).and_return(sample_ratio)
    allow(mock_config).to receive(:sample_keys).and_return(sample_keys)
    allow(mock_config).to receive(:unsampled_entries).and_return(unsampled)
    allow(mock_config).to receive(:sampled_entries_sent).and_return(samples_sent)
    allow(mock_config).to receive(:sampled_entries_dropped).and_return(samples_dropped)
    allow(mock_config).to receive(:sample_ratios).and_return(sample_ratios)

    allow(unsampled).to receive(:increment)
    allow(samples_sent).to receive(:increment)
    allow(samples_dropped).to receive(:increment)

    allow(samples_sent).to receive(:data).and_return(Hash[sent_values.map { |k, v| [{ sample_key: k }, v] }])
    allow(samples_dropped).to receive(:data).and_return(Hash[dropped_values.map { |k, v| [{ sample_key: k }, v] }])
    allow(sample_ratios).to receive(:data).and_return(Hash[ratio_values.map { |k, v| [{ sample_key: k }, v] }])
  end

  describe "#calculate_key_ratios" do
    context "with no samples counted" do
      it "doesn't set any ratios" do
        expect(sample_ratios).to_not receive(:set)

        sampler.__send__(:calculate_ratios)
      end
    end

    context "with entries on a single key" do
      let(:sent_values)    { { "foo" => 5  } }
      let(:dropped_values) { { "foo" => 45 } }

      it "gives a sample ratio equal to the overall ratio" do
        expect(sample_ratios).to receive(:observe).with(within(0.001).of(10), sample_key: "foo")

        sampler.__send__(:calculate_ratios)
      end
    end

    context "with entries on multiple keys" do
      let(:sent_values)    { { "foo" => 5,  "bar" => 10 } }
      let(:dropped_values) { { "foo" => 45, "bar" => 90 } }

      it "gives appropriate sample ratios for each key" do
        expect(sample_ratios).to receive(:observe).with(within(0.001).of(6.6666), sample_key: "foo")
        expect(sample_ratios).to receive(:observe).with(within(0.001).of(13.3333), sample_key: "bar")

        sampler.__send__(:calculate_ratios)
      end
    end

    context "with one very rare key" do
      let(:sent_values)    { { "foo" => 50,  "bar" => 100, "bunyip" => 1 } }
      let(:dropped_values) { { "foo" => 450, "bar" => 900 } }

      it "gives appropriate sample ratios for each key" do
        expect(sample_ratios).to receive(:observe).with(within(0.001).of(9.9933), sample_key: "foo")
        expect(sample_ratios).to receive(:observe).with(within(0.001).of(19.9866), sample_key: "bar")
        expect(sample_ratios).to receive(:observe).with(within(0.001).of(1), sample_key: "bunyip")

        sampler.__send__(:calculate_ratios)
      end
    end
  end

  describe "#sample" do
    context "with no sample keys" do
      it "always passes the message" do
        expect(sampler.sample("foo")).to eq([true, {}])
        expect(sampler.sample("bar")).to eq([true, {}])
      end

      it "never asks for a random number" do
        expect(sampler).to_not receive(:rand)

        sampler.sample("foo")
      end

      it "increments the unsampled counter" do
        expect(unsampled).to receive(:increment)

        sampler.sample("foo")
      end
    end

    context "with one simple sample key" do
      let(:sample_keys) { [[/x/, "ex"]] }

      context "with no prior entries" do
        it "passes an unmatched message without asking for a random number" do
          expect(sampler).to_not receive(:rand)

          expect(sampler.sample("foo")).to eq([true, {}])
        end

        it "passes the first matched message without consulting the oracle" do
          expect(sampler).to_not receive(:rand)

          expect(sampler.sample("xyzzy")).to eq([true, { sample_key: "ex", sample_ratio: 1 }])
        end

        it "increments the sent counter" do
          expect(samples_sent).to receive(:increment).with(sample_key: "ex")

          sampler.sample("xyzzy")
        end
      end

      context "with a key ratio set" do
        let(:ratio_values) { { "ex" => 10 } }

        it "passes an unmatched message without asking for a random number" do
          expect(sampler).to_not receive(:rand)

          expect(sampler.sample("foo")).to eq([true, {}])
        end

        context "when the oracle smiles upon us" do
          before(:each) do
            expect(sampler).to receive(:rand).and_return(0.09999999999)
          end

          it "passes the matched message" do
            expect(sampler.sample("xyzzy")).to eq([true, { sample_key: "ex", sample_ratio: 10 }])
          end

          it "increments the sent counter" do
            expect(samples_sent).to receive(:increment).with(sample_key: "ex")

            sampler.sample("xyzzy")
          end

          it "recalculates the sample ratios" do
            expect(sampler).to receive(:calculate_ratios)

            sampler.sample("xyzzy")
          end
        end

        context "when the oracle says no dice" do
          before(:each) do
            expect(sampler).to receive(:rand).and_return(0.1000000001)
          end

          it "drops the matched message" do
            expect(sampler.sample("xyzzy")).to eq([false])
          end

          it "increments the dropped counter" do
            expect(samples_dropped).to receive(:increment).with(sample_key: "ex")

            sampler.sample("xyzzy")
          end

          it "doesn't recalculate the sample ratios" do
            expect(sampler).to_not receive(:calculate_ratios)

            sampler.sample("xyzzy")
          end
        end
      end
    end

    context "with a backreferencing sample key" do
      let(:sample_keys) { [[/rc:(\d{3})/, "http_\\1"]] }

      it "passes an unmatched message without asking for a random number" do
        expect(sampler).to_not receive(:rand)

        expect(sampler.sample("foo")).to eq([true, {}])
      end

      it "passes the message with a substituted value" do
        expect(sampler).to_not receive(:rand)

        expect(sampler.sample("xyzzy rc:200")).to eq([true, { sample_key: "http_200", sample_ratio: 1 }])
      end

      it "increments the sent counter" do
        expect(samples_sent).to receive(:increment).with(sample_key: "http_200")

        sampler.sample("xyzzy rc:200")
      end
    end
  end
end
