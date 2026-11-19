module Healing
  # Scores field selector candidates against every container of the new page.
  #
  #   coverage   = containers where the selector yields a value that passes the type check / containers
  #   agreement  = known-good samples found among the extracted values / samples
  #   uniqueness = 1 / avg(matches per container), over containers with a match
  #   confidence = 0.4 coverage + 0.3 agreement + 0.2 stability + 0.1 uniqueness
  #
  # Candidates that pick the same nodes are collapsed (most stable wins).
  class CandidateScorer
    WEIGHTS = { coverage: 0.4, agreement: 0.3, stability: 0.2, uniqueness: 0.1 }.freeze

    def self.confidence(coverage:, agreement:, stability:, uniqueness:)
      (WEIGHTS[:coverage] * coverage + WEIGHTS[:agreement] * agreement +
        WEIGHTS[:stability] * stability + WEIGHTS[:uniqueness] * uniqueness).round(4)
    end

    # The hash stored in SelectorSuggestion#candidates.
    def self.row(candidate, coverage:, agreement:, uniqueness:, samples:)
      {
        "selector" => candidate.selector, "kind" => candidate.kind,
        "confidence" => confidence(coverage:, agreement:, stability: candidate.stability, uniqueness:),
        "coverage" => coverage.round(4), "agreement" => agreement.round(4),
        "stability" => candidate.stability, "uniqueness" => uniqueness.round(4), "samples" => samples
      }
    end

    # Several selectors often hit the same nodes; keep the most stable, then the shortest.
    def self.dedupe(rows_by_signature)
      rows_by_signature.group_by(&:first).map do |_, group|
        group.map(&:last).max_by { |row| [ row["stability"], -row["selector"].length ] }
      end
    end

    def self.call(candidates, **) = new(**).call(candidates)

    def initialize(containers:, samples:, extract:, value_type:, min_similarity: 0.85)
      @containers = containers
      @samples = samples
      @extract = extract
      @value_type = value_type
      @min_similarity = min_similarity
    end

    def call(candidates)
      self.class.dedupe(candidates.filter_map { |c| score(c) })
    end

    private

    def score(candidate)
      values = []
      signature = []
      match_counts = []

      @containers.each do |container|
        nodes = container.css(candidate.selector)
        next signature << nil if nodes.empty?

        match_counts << nodes.size
        first = nodes.first
        signature << first.pointer_id
        raw = @extract.to_s == "text" ? first.text : first[@extract]
        valid, value = Contracts::TypeValidator.call(raw, @value_type)
        values << value if valid
      end
      return nil if values.empty?

      row = self.class.row(
        candidate,
        coverage: values.size.to_f / @containers.size,
        agreement: agreement_for(values),
        uniqueness: match_counts.size.to_f / match_counts.sum,
        samples: values.first(3).map(&:to_s)
      )
      [ signature, row ]
    rescue Nokogiri::CSS::SyntaxError, Nokogiri::XML::XPath::SyntaxError
      nil
    end

    def agreement_for(values)
      return 0.0 if @samples.empty?

      url = @value_type.to_s == "url"
      hits = @samples.count do |sample|
        values.any? { |v| TextMatcher.same?(sample, v, url:, min_similarity: @min_similarity) }
      end
      hits.to_f / @samples.size
    end
  end
end
