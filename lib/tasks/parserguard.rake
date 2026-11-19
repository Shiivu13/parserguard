FIXTURES_DIR = Rails.root.join("spec/fixtures/serp/google")

namespace :parserguard do
  desc "Import SERP fixtures as snapshots (DIR=..., defaults to the google fixtures)"
  task ingest_fixtures: :environment do
    Ingestion::FixtureImporter.call(dir: ENV.fetch("DIR", FIXTURES_DIR.to_s)).each do |result|
      next warn("FAIL #{result.error_message}") if result.failure?

      snap = result.value
      puts "#{result.meta[:duplicate] ? 'dup' : 'new'} #{snap.label} #{snap.source_ref}#{' (baseline)' if snap.baseline}"
    end
  end

  desc "Capture one snapshot from URL=... or a SerpApi QUERY=... (needs SERPAPI_KEY)"
  task fetch: :environment do
    engine = ENV.fetch("ENGINE", "google")
    abort "Set URL=... or QUERY=..." if ENV["URL"].blank? && ENV["QUERY"].blank?

    fetched = ENV["URL"].present? ? Ingestion::UrlFetcher.call(ENV["URL"]) : Ingestion::SerpApiFetcher.call(query: ENV["QUERY"], engine:)
    abort "FAIL #{fetched.error_message}" if fetched.failure?

    created = Ingestion::SnapshotCreator.call(
      html: fetched.value, engine:, query: ENV["QUERY"], charset: fetched.meta[:charset],
      source: ENV["URL"].present? ? "url" : "serpapi",
      source_ref: fetched.meta[:source_ref] || fetched.meta[:final_url]
    )
    abort "FAIL #{created.error_message}" if created.failure?
    puts "#{created.meta[:duplicate] ? 'dup' : 'new'} #{created.value.label}"
  end

  desc "Load config/contracts/*.yml (FORCE=1 overwrites contracts that already exist)"
  task load_contracts: :environment do
    Contracts::Loader.call(force: ENV["FORCE"].present?).each do |r|
      puts r.ok? ? "#{r.meta[:action]} #{r.value.key} v#{r.value.version}" : "FAIL #{r.meta[:file]}: #{r.error_message}"
    end
  end

  desc "Run active contracts on the latest snapshot of their engine (SNAPSHOT=id to pick one)"
  task run: :environment do
    ParserContract.active.each do |contract|
      snapshot = ENV["SNAPSHOT"] ? Snapshot.find(ENV["SNAPSHOT"]) : Snapshot.where(engine: contract.engine).recent.first
      next puts("skip #{contract.key}: no snapshots") unless snapshot

      run = Contracts::Runner.call(contract, snapshot)
      puts format("%-28s %-28s %-6s rate=%.2f containers=%d", contract.key, snapshot.label, run.status, run.extraction_rate, run.container_count)
    end
  end

  desc "Compare every non-baseline snapshot (or SNAPSHOT=id) with its baseline"
  task detect: :environment do
    scope = ENV["SNAPSHOT"] ? Snapshot.where(_id: ENV["SNAPSHOT"]) : Snapshot.where(baseline: false)
    scope.order_by(captured_at: :asc).each do |snapshot|
      result = Drift::Detector.call(snapshot)
      next warn("skip #{snapshot.label}: #{result.error_message}") if result.failure?

      print_event(snapshot, result.value)
    end
  end

  desc "Suggest selectors: CONTRACT=google/organic_results FIELD=title|_container SNAPSHOT=id"
  task heal: :environment do
    engine, type = ENV.fetch("CONTRACT").split("/", 2)
    contract = ParserContract.find_by(engine:, result_type: type)
    result = Healing::Healer.call(contract:, field_name: ENV.fetch("FIELD"), snapshot: Snapshot.find(ENV.fetch("SNAPSHOT")))
    abort "FAIL #{result.error_message}" if result.failure?

    puts "suggestion #{result.value.id} for #{contract.key}##{result.value.field_name}"
    result.value.candidates.each do |c|
      puts format("  %.3f  %-40s cov=%.2f agr=%.2f stab=%.2f", c["confidence"], c["selector"], c["coverage"], c["agreement"], c["stability"])
    end
    puts "  (no candidates, needs a manual fix)" if result.value.candidates.empty?
  end

  desc "Create an API key (NAME=...). The token is printed once and never stored."
  task api_key: :environment do
    puts ApiKey.generate!(name: ENV.fetch("NAME", "default")).last
  end

  desc "Load contracts, import the fixtures, detect drift and heal (no background jobs)"
  task demo: :environment do
    Contracts::Loader.call
    Ingestion::FixtureImporter.call(dir: FIXTURES_DIR)
    Snapshot.where(baseline: false).order_by(captured_at: :asc).each do |snapshot|
      result = Drift::Detector.call(snapshot)
      next unless result.ok? && result.meta[:created]

      event = result.value
      event.broken_fields.each do |f|
        Healing::Healer.call(contract: ParserContract.find(f["contract_id"]), field_name: f["field"], snapshot:, drift_event: event)
      end
      print_event(snapshot, event)
    end
    puts "Open http://localhost:3000 to review #{SelectorSuggestion.pending.count} pending suggestions."
  end

  desc "Run every fixture manifest through ingest, drift and healing; exits 1 on failure"
  task regression: :environment do
    report = Regression::Runner.call
    report.each do |c|
      actual = c.actual.is_a?(Float) ? c.actual.round(4) : c.actual
      puts format("%-4s %-8s %-24s %-26s expected %-18s got %s", c.ok ? "ok" : "FAIL", c.engine, c.fixture, c.check, c.expected, actual)
    end
    failed = report.count { |c| !c.ok }
    puts "#{report.size} checks, #{failed} failed"
    exit(1) if failed.positive? || report.empty?
  end

  def print_event(snapshot, event)
    fields = event.broken_fields.map { |f| f["field"] }.join(",")
    puts format("%-26s %-7s score=%.3f broken=%s", snapshot.label, event.severity, event.drift_score, fields)
  end
end
