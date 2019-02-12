# frozen_string_literal: true

module Mobystash
  class Sampler
    def initialize(config)
      @config = config
    end

    def sample(msg)
      k = matching_key(msg)

      if k.nil?
        @config.unsampled_entries.increment
        [true, {}]
      else
        key_ratio = @config.sample_ratios.data[sample_key: k]
        [].tap do |result|
          if key_ratio.nil?
            # A previously unseen sample key is the rarest of all
            # possible unicorns, so its sample ratio is always going
            # to be 1.
            result[0] = true
            result[1] = { sample_key: k, sample_ratio: 1 }
          elsif rand * key_ratio < 1
            result[0] = true
            result[1] = { sample_key: k, sample_ratio: key_ratio }
          else
            result[0] = false
          end

          if result.first
            @config.sampled_entries_sent.increment(sample_key: k)
            calculate_ratios
          else
            @config.sampled_entries_dropped.increment(sample_key: k)
          end
        end
      end
    end

    private

    def matching_key(msg)
      @config.sample_keys.each do |re, k|
        if (md = re.match(msg))
          k = k.dup
          md.to_a[1..-1].each_with_index do |v, i|
            k.gsub!(/(?<=[^\\])\\#{i + 1}/, v)
          end
          return k
        end
      end

      nil
    end

    def calculate_ratios
      counts = sample_count_totals

      total_entries = counts.values.inject(0) { |t, v| t + v }
      nominal_total_out = total_entries / @config.sample_ratio.to_f
      nominal_out_per_key = nominal_total_out / counts.length

      counts.each do |key, tot|
        @config.sample_ratios.observe([1, tot / nominal_out_per_key].max, sample_key: key)
      end
    end

    def sample_count_totals
      Hash.new(0).tap do |counts|
        @config.sampled_entries_sent.data.each do |k, v|
          counts[k[:sample_key]] += v
        end
        @config.sampled_entries_dropped.data.each do |k, v|
          counts[k[:sample_key]] += v
        end
      end
    end
  end
end
