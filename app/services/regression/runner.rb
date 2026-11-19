module Regression
  # Replays every fixture manifest (spec/fixtures/serp/<engine>/manifest.yml)
  # through the real pipeline: ingest -> contracts -> drift -> heal -> accept.
  #
  # Runs in a throwaway MongoDB database so it never touches app data, and
  # returns plain check rows so the rake task and the spec share one source
  # of truth.
  #
  # Manifest expectations per fixture (all optional):
  #   <result_type>_rate:        [min, max]  extraction rate with the original contract
  #   drift_score:               [min, max]  vs the first fixture (baseline)
  #   severity:                  name or [names]
  #   healed_rate_min:           rate after accepting top suggestions (up to MAX_HEAL_ROUNDS)
  #   max_candidate_confidence:  every suggestion's top candidate must stay below this
  class Runner
    MAX_HEAL_ROUNDS = 3
    Check = Data.define(:engine, :fixture, :check, :expected, :actual, :ok)

    def self.call(**) = new(**).call

    def initialize(root: Rails.root.join("spec/fixtures/serp"), contracts_dir: Rails.root.join("config/contracts"))
      @root = Pathname(root)
      @contracts_dir = Pathname(contracts_dir)
    end

    def call
      with_scratch_database do
        @root.glob("*/manifest.yml").sort.flat_map { |manifest| run_manifest(manifest) }
      end
    end

    private

    def with_scratch_database
      name = "parserguard_regression_#{Process.pid}_#{SecureRandom.hex(3)}"
      Mongoid.override_database(name)
      Rails.autoloaders.main.eager_load_dir(Rails.root.join("app/models")) # create_indexes only sees loaded models
      Mongoid::Tasks::Database.create_indexes
      yield
    ensure
      Mongoid.default_client.use(name).database.drop if name
      Mongoid.override_database(nil)
    end

    def run_manifest(path)
      engine = path.dirname.basename.to_s
      fixtures = YAML.safe_load_file(path).fetch("fixtures")
      snapshots = Ingestion::FixtureImporter.call(dir: path.dirname, engine:).map(&:value)
      fixtures.zip(snapshots).flat_map do |entry, snapshot|
        reset_contracts
        check_fixture(engine, entry, snapshot)
      end
    end

    def reset_contracts
      SelectorSuggestion.delete_all
      ContractRun.delete_all
      DriftEvent.delete_all
      ParserContract.delete_all
      Contracts::Loader.call(dir: @contracts_dir)
    end

    def check_fixture(engine, entry, snapshot)
      @checks = []
      @engine = engine
      @file = entry.fetch("file")
      expect = entry.fetch("expect", {})
      doc = Html::Normalizer.call(snapshot.html)
      contracts = ParserContract.where(engine:).to_a

      check_rates(expect, contracts, doc)
      check_drift(expect, snapshot)
      check_healing(expect, contracts, snapshot, doc) if expect.key?("healed_rate_min") || expect.key?("max_candidate_confidence")
      @checks
    end

    def add(name, expected, actual, ok)
      @checks << Check.new(engine: @engine, fixture: @file, check: name, expected:, actual:, ok:)
    end

    def check_rates(expect, contracts, doc)
      contracts.each do |contract|
        range = expect["#{contract.result_type}_rate"]
        next unless range

        rate = Contracts::Runner.evaluate(contract, doc).extraction_rate
        add("#{contract.result_type}_rate", range, rate, in_range?(rate, range))
      end
    end

    def check_drift(expect, snapshot)
      event = snapshot.baseline ? nil : Drift::Detector.call(snapshot).value
      if (range = expect["drift_score"])
        score = event ? event.drift_score : 0.0
        add("drift_score", range, score, in_range?(score, range))
      end
      if (wanted = expect["severity"])
        severity = event ? event.severity : "none"
        add("severity", wanted, severity, Array(wanted).include?(severity))
      end
    end

    def check_healing(expect, contracts, snapshot, doc)
      top_confidences = []
      worst = contracts.map { |c| heal_until_passing(c, snapshot, doc, top_confidences) }.min || 0.0
      best = top_confidences.max || 0.0

      if (min = expect["healed_rate_min"])
        add("healed_rate", ">= #{min}", worst, worst >= min)
      end
      if (max = expect["max_candidate_confidence"])
        add("max_candidate_confidence", "< #{max}", best, best < max)
      end
    end

    # Accept the top candidate for each failing field, re-evaluate, repeat.
    def heal_until_passing(contract, snapshot, doc, top_confidences)
      rate = 0.0
      MAX_HEAL_ROUNDS.times do
        evaluation = Contracts::Runner.evaluate(contract.reload, doc)
        rate = evaluation.extraction_rate
        break if rate >= contract.min_extraction_rate

        failing = failing_fields(contract, evaluation)
        progressed = failing.map do |field|
          suggestion = Healing::Healer.call(contract:, field_name: field, snapshot:).value
          next false unless suggestion&.top_candidate

          top_confidences << suggestion.top_candidate["confidence"]
          Healing::SuggestionAcceptor.call(suggestion).ok?
        end
        break unless progressed.any?
      end
      Contracts::Runner.evaluate(contract.reload, doc).extraction_rate.then { |r| [ r, rate ].max }
    end

    def failing_fields(contract, evaluation)
      return [ ParserContract::CONTAINER_FIELD ] if evaluation.container_count.zero?

      evaluation.field_stats.select { |s| s["required"] && s["rate"] < contract.min_extraction_rate }.map { |s| s["name"] }
    end

    def in_range?(value, range)
      min, max = Array(range)
      value >= min.to_f - 1e-9 && value <= (max || min).to_f + 1e-9
    end
  end
end
