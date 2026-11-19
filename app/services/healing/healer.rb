module Healing
  # Builds a SelectorSuggestion for one broken field (or "_container").
  #
  # 1. Samples: known-good values of the field from the baseline's last passing run.
  # 2. Locate each sample in the new DOM (TextMatcher).
  # 3. Generate selectors from each located node (SelectorGenerator).
  # 4. Score them across the whole page (CandidateScorer), keep the top N.
  #
  # Container healing locates samples of the anchor field (first required
  # string field), climbs to the item boundary (lowest ancestor whose parent
  # holds more than one sample) and scores selectors for that boundary by
  # how well the contract would extract with it.
  class Healer
    def self.call(**) = new(**).call

    def initialize(contract:, field_name:, snapshot:, baseline: nil, drift_event: nil)
      @contract = contract
      @field_name = field_name.to_s
      @snapshot = snapshot
      @baseline = baseline || Snapshot.baseline_for(*snapshot.target)
      @drift_event = drift_event
      @config = Rails.application.config.parserguard[:healing]
    end

    def call
      return Result.failure("no baseline for #{@snapshot.target.join('/')}") unless @baseline
      return Result.failure("unknown field #{@field_name}") unless container? || @contract.field_spec(@field_name)

      existing = SelectorSuggestion.pending.where(contract_id: @contract.id, field_name: @field_name, snapshot_id: @snapshot.id).first
      return Result.success(existing, created: false) if existing

      samples = baseline_samples
      return Result.failure("no known-good #{sample_field} values in baseline #{@baseline.label}") if samples.empty?

      doc = Html::Normalizer.call(@snapshot.html)
      candidates = container? ? heal_container(doc, samples) : heal_field(doc, samples)

      suggestion = SelectorSuggestion.create!(
        contract: @contract, field_name: @field_name, snapshot: @snapshot, drift_event: @drift_event,
        old_selector: @contract.selector_for(@field_name), candidates: rank(candidates)
      )
      Result.success(suggestion, created: true)
    end

    private

    def container? = @field_name == ParserContract::CONTAINER_FIELD

    def sample_field = container? ? anchor_spec&.name : @field_name

    def anchor_spec
      @anchor_spec ||= @contract.required_fields.detect { |f| f.value_type == "string" } || @contract.required_fields.first
    end

    # Items from the baseline's latest passing run; runs the contract on the
    # baseline (and stores the run) when none exists yet.
    def baseline_samples
      run = ContractRun.where(contract_id: @contract.id, snapshot_id: @baseline.id, status: "passed").recent.first
      run ||= Contracts::Runner.call(@contract, @baseline).then { |r| r.passed? ? r : nil }
      return [] unless run && sample_field

      run.items.filter_map { |item| item[sample_field] }.uniq.first(@config[:max_samples])
    end

    def heal_field(doc, samples)
      spec = @contract.field_spec(@field_name)
      containers = Contracts::Runner.containers(doc, @contract)
      return [] if containers.empty?

      url = spec.value_type == "url"
      by_pointer = containers.index_by(&:pointer_id)
      raw = samples.flat_map do |sample|
        node = TextMatcher.find(containers, sample, url:, min_similarity: @config[:min_similarity], max_length: @config[:max_text_length])
        next [] unless node

        container = ([ node ] + node.ancestors.to_a).detect { |n| by_pointer.key?(n.pointer_id) }
        next [] if container.nil? || container == node

        same_value_chain(node, container, url).flat_map { |n| SelectorGenerator.call(n, root: container) }
      end

      CandidateScorer.call(
        raw.uniq(&:selector),
        containers:, samples:, extract: spec.extract, value_type: spec.value_type,
        min_similarity: @config[:min_similarity]
      )
    end

    # The matched node plus ancestors (inside the container) that carry the same text.
    def same_value_chain(node, container, url)
      return [ node ] if url

      text = TextMatcher.normalize(node.text)
      [ node ] + node.ancestors.take_while { |a| a != container && a.element? && TextMatcher.normalize(a.text) == text }
    end

    def heal_container(doc, samples)
      spec = anchor_spec
      url = spec.value_type == "url"
      roots = doc.css(@contract.scope_selector.presence || "body").to_a
      roots = [ doc.at_css("body") || doc ] if roots.empty?

      matches = samples.filter_map do |sample|
        TextMatcher.find(roots, sample, url:, min_similarity: @config[:min_similarity], max_length: @config[:max_text_length])
      end.uniq(&:pointer_id)
      return [] if matches.size < 2

      ancestor_ids = matches.to_h { |m| [ m.pointer_id, m.ancestors.to_set(&:pointer_id) ] }
      boundaries = matches.filter_map { |m| item_boundary(m, ancestor_ids) }.uniq(&:pointer_id)
      raw = boundaries.flat_map do |b|
        root = roots.detect { |r| b.ancestors.include?(r) } || b.parent
        SelectorGenerator.call(b, root:)
      end

      score_containers(doc, raw.uniq(&:selector), matches)
    end

    # Lowest ancestor of `node` whose parent contains more than one matched sample.
    # ancestor_ids: { match pointer_id => Set of its ancestors' pointer_ids }
    def item_boundary(node, ancestor_ids)
      current = node
      while (parent = current.parent) && parent.element?
        return current if ancestor_ids.count { |_, ids| ids.include?(parent.pointer_id) } > 1

        current = parent
      end
      nil
    end

    def score_containers(doc, candidates, matches)
      scored = candidates.filter_map do |candidate|
        containers = Contracts::Runner.containers(doc, @contract, container_selector: candidate.selector)
        next if containers.empty?

        container_ids = containers.to_set(&:pointer_id)
        covered = matches.count { |m| m.ancestors.any? { |a| container_ids.include?(a.pointer_id) } }
        coverage = covered.to_f / matches.size

        trial = @contract.clone
        trial.container_selector = candidate.selector
        rate = Contracts::Runner.evaluate(trial, doc).extraction_rate

        uniqueness = [ containers.size, matches.size ].min.to_f / [ containers.size, matches.size ].max
        confidence = CandidateScorer.confidence(coverage:, agreement: rate, stability: candidate.stability, uniqueness:)
        [ container_ids.to_a.sort, {
          "selector" => candidate.selector, "kind" => candidate.kind, "confidence" => confidence,
          "coverage" => coverage.round(4), "agreement" => rate.round(4), "stability" => candidate.stability,
          "uniqueness" => uniqueness.round(4), "samples" => [ "#{containers.size} containers" ]
        } ]
      end

      scored.group_by(&:first).map { |_, group| group.map(&:last).max_by { |r| [ r["stability"], -r["selector"].length ] } }
    end

    def rank(rows)
      rows.select { |r| r["confidence"] >= @config[:min_confidence] }
          .sort_by { |r| [ -r["confidence"], -r["stability"], r["selector"].length ] }
          .first(@config[:max_candidates])
    end
  end
end
