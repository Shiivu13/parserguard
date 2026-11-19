module Drift
  # Compares a new snapshot against its target's baseline, runs every active
  # contract for the engine on it, and records one DriftEvent per pair.
  #
  # Severity:
  #   broken - some contract finds no containers or its rate < broken_rate
  #   major  - any required field below the contract minimum, or (no contracts
  #            for this engine) drift_score >= major_threshold
  #   minor  - drift_score >= minor_threshold
  #   none   - otherwise
  # When contracts exist and all pass, structure alone never escalates past
  # minor: an ad block or footer change is worth logging, not paging anyone.
  class Detector
    def self.call(candidate, baseline: nil) = new(candidate, baseline).call

    def initialize(candidate, baseline)
      @candidate = candidate
      @baseline = baseline || Snapshot.baseline_for(*candidate.target)
      @config = Rails.application.config.parserguard[:drift]
    end

    def call
      return Result.failure("no baseline for #{@candidate.target.join('/')}") unless @baseline
      return Result.failure("snapshot is the baseline") if @baseline.id == @candidate.id

      existing = DriftEvent.where(baseline_snapshot_id: @baseline.id, candidate_snapshot_id: @candidate.id).first
      return Result.success(existing, created: false) if existing

      comparison = Comparator.call(@baseline, @candidate)
      runs = run_contracts
      broken = broken_fields(runs)

      event = DriftEvent.create!(
        baseline_snapshot: @baseline, candidate_snapshot: @candidate,
        engine: @candidate.engine, locale: @candidate.locale, device: @candidate.device,
        drift_score: comparison.drift_score, tag_drift: comparison.tag_drift, class_drift: comparison.class_drift,
        added_paths: comparison.added_paths, removed_paths: comparison.removed_paths,
        broken_fields: broken,
        severity: severity(comparison.drift_score, runs, broken)
      )
      Result.success(event, created: true, runs:)
    rescue Mongo::Error::OperationFailure => e
      # Concurrent detector for the same pair won the unique index.
      raise unless MongoErrors.duplicate_key?(e)

      Result.success(DriftEvent.find_by(baseline_snapshot_id: @baseline.id, candidate_snapshot_id: @candidate.id), created: false)
    end

    private

    def run_contracts
      contracts = ParserContract.active.where(engine: @candidate.engine).to_a
      return [] if contracts.empty?

      doc = Html::Normalizer.call(@candidate.html)
      contracts.map { |contract| Contracts::Runner.call(contract, @candidate, doc:) }
    end

    def broken_fields(runs)
      runs.flat_map do |run|
        contract = run.contract
        base = { "contract_id" => contract.id.to_s, "contract" => contract.key }
        if run.container_count.zero?
          [ base.merge("field" => ParserContract::CONTAINER_FIELD, "rate" => 0.0) ]
        else
          run.failing_fields(contract.min_extraction_rate).map { |f| base.merge("field" => f, "rate" => run.field_rate(f)) }
        end
      end
    end

    def severity(score, runs, broken)
      return "broken" if runs.any? { |r| r.container_count.zero? || r.extraction_rate < @config[:broken_rate] }
      return "major" if broken.any?
      return "major" if runs.empty? && score >= @config[:major_threshold]
      return "minor" if score >= @config[:minor_threshold]

      "none"
    end
  end
end
