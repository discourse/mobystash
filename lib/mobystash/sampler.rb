# frozen_string_literal: true

class Mobystash::Sampler
  attr_reader :metrics

  def initialize(config, metrics)
    @config = config
    @metrics = metrics
  end

  def sample(msg)
    k = matching_key(msg)

    if k.nil?
      @metrics.unsampled_entries_total.increment
      [true, {}]
    else
      key_ratio = @metrics.sample_ratios.get(labels: { sample_key: k })
      [].tap do |result|
        if key_ratio == 0.0 || key_ratio.nil?
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
          @metrics.sampled_entries_sent_total.increment(labels: { sample_key: k })
          calculate_ratios
        else
          @metrics.sampled_entries_dropped_total.increment(labels: { sample_key: k })
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
      total_over_nominal_per_key = tot / nominal_out_per_key
      total_over_nominal_per_key = 0 if total_over_nominal_per_key.nan? # Catch divide by 0
      @metrics.sample_ratios.set([1, total_over_nominal_per_key].max, labels: { sample_key: key })
    end
  end

  def sample_count_totals
    Hash.new(0).tap do |counts|

      @config.sample_keys.each do |re, k|
        counts[k] += @metrics.sampled_entries_sent_total.get(labels: { sample_key: k })
        counts[k] += @metrics.sampled_entries_dropped_total.get(labels: { sample_key: k })
      end
    end
  end
end
