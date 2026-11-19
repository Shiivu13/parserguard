module Drift
  # Pure math over two snapshots' structure histograms.
  #
  #   J(A, B)      = sum_k min(A_k, B_k) / sum_k max(A_k, B_k)   (weighted Jaccard; 1.0 if both empty)
  #   tag_drift    = 1 - J(tag_base, tag_cand)
  #   class_drift  = 1 - J(class_base, class_cand)
  #   drift_score  = w_tag * tag_drift + w_class * class_drift
  class Comparator
    Comparison = Data.define(:drift_score, :tag_drift, :class_drift, :added_paths, :removed_paths)

    def self.call(baseline, candidate, config: Rails.application.config.parserguard[:drift])
      new(config).compare(
        tag: [ baseline.tag_histogram, candidate.tag_histogram ],
        klass: [ baseline.class_histogram, candidate.class_histogram ]
      )
    end

    def self.weighted_jaccard(a, b)
      keys = a.keys | b.keys
      return 1.0 if keys.empty?

      max = keys.sum { |k| [ a.fetch(k, 0), b.fetch(k, 0) ].max }
      min = keys.sum { |k| [ a.fetch(k, 0), b.fetch(k, 0) ].min }
      min.to_f / max
    end

    def initialize(config)
      @tag_weight = config.fetch(:tag_weight, 0.6)
      @class_weight = config.fetch(:class_weight, 0.4)
      @top = config.fetch(:top_paths, 50)
    end

    def compare(tag:, klass:)
      tag_base, tag_cand = tag.map { |pairs| to_hash(pairs) }
      class_base, class_cand = klass.map { |pairs| to_hash(pairs) }

      tag_drift = 1.0 - self.class.weighted_jaccard(tag_base, tag_cand)
      class_drift = 1.0 - self.class.weighted_jaccard(class_base, class_cand)

      Comparison.new(
        drift_score: (@tag_weight * tag_drift + @class_weight * class_drift).round(4).clamp(0.0, 1.0),
        tag_drift: tag_drift.round(4),
        class_drift: class_drift.round(4),
        added_paths: deltas(class_cand, class_base),
        removed_paths: deltas(class_base, class_cand)
      )
    end

    private

    def to_hash(pairs) = Array(pairs).to_h { |path, count| [ path, count.to_i ] }

    # Paths more frequent in `from` than in `to`, biggest difference first.
    def deltas(from, to)
      from.filter_map { |path, n| d = n - to.fetch(path, 0); { "path" => path, "delta" => d } if d.positive? }
          .sort_by { |h| [ -h["delta"], h["path"] ] }
          .first(@top)
    end
  end
end
