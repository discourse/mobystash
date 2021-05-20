require_relative './spec_helper'

require 'mobystash/sampler'

describe Mobystash::Sampler do
  uses_logger


  let(:mock_metrics)    { MockMetrics.new }
  let(:mock_writer)     { instance_double(LogstashWriter) }
  let(:mock_config)     { MockConfig.new(logger) }

  let(:sampler) { Mobystash::Sampler.new(mock_config, mock_metrics) }

  before(:each) do
    mock_config.set_sample_ratio(10)
  end

  describe "#calculate_key_ratios" do
    context "with entries on a single key" do

      it "gives a sample ratio equal to the overall ratio" do
        mock_config.set_sample_keys([[/foo/, "foo"]])

        sampler.metrics.sampled_entries_sent_total.increment(labels: { sample_key: "foo"}, by: 5)
        sampler.metrics.sampled_entries_dropped_total.increment(labels: { sample_key: "foo"}, by: 45)

        expect(sampler.metrics.sample_ratios).to receive(:set).with(within(0.001).of(10), labels: { sample_key: "foo" })

        sampler.__send__(:calculate_ratios)
      end
    end

    context "with entries on multiple keys" do
      it "gives appropriate sample ratios for each key" do
        mock_config.set_sample_keys([[/foo/, "foo"], [/bar/, "bar"]])
        mock_config.set_sample_ratio(10)

        sampler.metrics.sampled_entries_sent_total.increment(labels: { sample_key: "foo"}, by: 5)
        sampler.metrics.sampled_entries_sent_total.increment(labels: { sample_key: "bar"}, by: 10)

        sampler.metrics.sampled_entries_dropped_total.increment(labels: { sample_key: "foo"}, by: 45)
        sampler.metrics.sampled_entries_dropped_total.increment(labels: { sample_key: "bar"}, by: 90)

        expect(sampler.metrics.sample_ratios).to receive(:set).with(within(0.001).of(6.6666), labels: { sample_key: "foo" })
        expect(sampler.metrics.sample_ratios).to receive(:set).with(within(0.001).of(13.3333), labels: { sample_key: "bar" })

        sampler.__send__(:calculate_ratios)
      end
    end

    context "with one very rare key" do
      it "gives appropriate sample ratios for each key" do
        mock_config.set_sample_keys([[/foo/, "foo"], [/bar/, "bar"], [/bunyip/, 'bunyip']])
        mock_config.set_sample_ratio(10)

        sampler.metrics.sampled_entries_sent_total.increment(labels: { sample_key: "foo"}, by: 50)
        sampler.metrics.sampled_entries_sent_total.increment(labels: { sample_key: "bar"}, by: 100)
        sampler.metrics.sampled_entries_sent_total.increment(labels: { sample_key: "bunyip"}, by: 1)

        sampler.metrics.sampled_entries_dropped_total.increment(labels: { sample_key: "foo"}, by: 450)
        sampler.metrics.sampled_entries_dropped_total.increment(labels: { sample_key: "bar"}, by: 900)

        expect(sampler.metrics.sample_ratios).to receive(:set).with(within(0.001).of(9.9933), labels: { sample_key: "foo" })
        expect(sampler.metrics.sample_ratios).to receive(:set).with(within(0.001).of(19.9866), labels: { sample_key: "bar" })
        expect(sampler.metrics.sample_ratios).to receive(:set).with(within(0.001).of(1), labels: { sample_key: "bunyip" })

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
        expect(sampler.metrics.unsampled_entries_total).to receive(:increment)

        sampler.sample("foo")
      end
    end

    context "with one simple sample key" do
      before do
        mock_config.set_sample_keys([[/x/, "ex"]])
      end

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
          expect(sampler.metrics.sampled_entries_sent_total).to receive(:increment).with(labels: { sample_key: "ex" })

          sampler.sample("xyzzy")
        end
      end

      context "with a key ratio set" do
        before do
          sampler.metrics.sample_ratios.set(10, labels: { sample_key: "ex" })
        end

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
            expect(sampler.metrics.sampled_entries_sent_total).to receive(:increment).with(labels: { sample_key: "ex" })

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
            expect(sampler.metrics.sampled_entries_dropped_total).to receive(:increment).with(labels: { sample_key: "ex" })

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
      before do
        mock_config.set_sample_keys([[/rc:(\d{3})/, "http_\\1"]])
      end

      it "passes an unmatched message without asking for a random number" do
        expect(sampler).to_not receive(:rand)

        expect(sampler.sample("foo")).to eq([true, {}])
      end

      it "passes the message with a substituted value" do
        expect(sampler).to_not receive(:rand)

        expect(sampler.sample("xyzzy rc:200")).to eq([true, { sample_key: "http_200", sample_ratio: 1 }])
      end

      it "increments the sent counter" do
        expect(sampler.metrics.sampled_entries_sent_total).to receive(:increment).with(labels: { sample_key: "http_200" })

        sampler.sample("xyzzy rc:200")
      end
    end
  end
end
