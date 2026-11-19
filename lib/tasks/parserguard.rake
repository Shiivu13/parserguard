namespace :parserguard do
  desc "Import SERP fixtures as snapshots (DIR defaults to spec/fixtures/serp/google)"
  task ingest_fixtures: :environment do
    dir = ENV.fetch("DIR", Rails.root.join("spec/fixtures/serp/google").to_s)
    Ingestion::FixtureImporter.call(dir:).each do |result|
      if result.ok?
        snap = result.value
        status = result.meta[:duplicate] ? "dup " : "new "
        puts "#{status} #{snap.label} #{snap.source_ref}#{' (baseline)' if snap.baseline}"
      else
        warn "FAIL #{result.error_message}"
      end
    end
  end

  desc "Fetch one URL (URL=...) or SerpApi search (QUERY=..., needs SERPAPI_KEY) into a snapshot"
  task fetch: :environment do
    engine = ENV.fetch("ENGINE", "google")
    fetched =
      if ENV["URL"].present?
        Ingestion::UrlFetcher.call(ENV["URL"])
      elsif ENV["QUERY"].present?
        Ingestion::SerpApiFetcher.call(query: ENV["QUERY"], engine:)
      else
        abort "Set URL=... or QUERY=..."
      end
    abort "FAIL #{fetched.error_message}" if fetched.failure?

    source = ENV["URL"].present? ? "url" : "serpapi"
    created = Ingestion::SnapshotCreator.call(
      html: fetched.value, engine:, source:, query: ENV["QUERY"],
      source_ref: fetched.meta[:source_ref] || fetched.meta[:final_url]
    )
    abort "FAIL #{created.error_message}" if created.failure?
    puts "#{created.meta[:duplicate] ? 'dup' : 'new'} #{created.value.label}"
  end
end

namespace :parserguard do
  desc "Load config/contracts/*.yml (FORCE=1 overwrites existing contracts)"
  task load_contracts: :environment do
    Contracts::Loader.call(force: ENV["FORCE"].present?).each do |r|
      puts r.ok? ? "#{r.meta[:action]} #{r.value.key} v#{r.value.version}" : "FAIL #{r.meta[:file]}: #{r.error_message}"
    end
  end

  desc "Run active contracts on the latest snapshot of each engine (SNAPSHOT=id to pick one)"
  task run: :environment do
    ParserContract.active.each do |contract|
      snapshot = ENV["SNAPSHOT"] ? Snapshot.find(ENV["SNAPSHOT"]) : Snapshot.where(engine: contract.engine).recent.first
      next puts("skip #{contract.key}: no snapshots") unless snapshot

      run = Contracts::Runner.call(contract, snapshot)
      puts format("%-28s %-28s %-6s rate=%.2f containers=%d", contract.key, snapshot.label, run.status, run.extraction_rate, run.container_count)
    end
  end
end

namespace :parserguard do
  desc "Detect drift for every non-baseline snapshot (or SNAPSHOT=id) against its baseline"
  task detect: :environment do
    scope = ENV["SNAPSHOT"] ? Snapshot.where(_id: ENV["SNAPSHOT"]) : Snapshot.where(baseline: false)
    scope.light.order_by(captured_at: :asc).each do |snapshot|
      result = Drift::Detector.call(Snapshot.find(snapshot.id))
      next warn("skip #{snapshot.label}: #{result.error_message}") if result.failure?

      e = result.value
      fields = e.broken_fields.map { |f| f["field"] }.join(",")
      puts format("%-24s score=%.3f %-7s broken=[%s]", snapshot.label, e.drift_score, e.severity, fields)
    end
  end
end

namespace :parserguard do
  desc "Suggest selectors: CONTRACT=google/organic_results FIELD=title|_container SNAPSHOT=id"
  task heal: :environment do
    engine, type = ENV.fetch("CONTRACT").split("/", 2)
    contract = ParserContract.find_by(engine:, result_type: type)
    snapshot = Snapshot.find(ENV.fetch("SNAPSHOT"))
    result = Healing::Healer.call(contract:, field_name: ENV.fetch("FIELD"), snapshot:)
    abort "FAIL #{result.error_message}" if result.failure?

    puts "suggestion #{result.value.id} for #{contract.key}##{result.value.field_name}"
    result.value.candidates.each do |c|
      puts format("  %.3f  %-40s cov=%.2f agr=%.2f stab=%.2f", c["confidence"], c["selector"], c["coverage"], c["agreement"], c["stability"])
    end
    puts "  (no candidates: manual fix needed)" if result.value.candidates.empty?
  end
end

namespace :parserguard do
  desc "Create an API key (NAME=...). The token is printed once."
  task api_key: :environment do
    _key, token = ApiKey.generate!(name: ENV.fetch("NAME", "default"))
    puts token
  end
end

namespace :parserguard do
  desc "Demo: load contracts, import fixtures, detect drift and heal synchronously"
  task demo: :environment do
    Contracts::Loader.call
    Ingestion::FixtureImporter.call(dir: Rails.root.join("spec/fixtures/serp/google"))
    Snapshot.where(baseline: false).order_by(captured_at: :asc).each do |snapshot|
      result = Drift::Detector.call(snapshot)
      next unless result.ok? && result.meta[:created]

      event = result.value
      event.broken_fields.each do |f|
        contract = ParserContract.find(f["contract_id"])
        Healing::Healer.call(contract:, field_name: f["field"], snapshot:, drift_event: event)
      end
      puts format("%-26s %-7s score=%.3f broken=%s", snapshot.label, event.severity, event.drift_score,
                  event.broken_fields.map { |f| f["field"] }.join(","))
    end
    puts "Open http://localhost:3000 to review #{SelectorSuggestion.pending.count} pending suggestions."
  end
end

namespace :parserguard do
  desc "Replay fixture manifests through ingest/drift/heal; exits 1 on any failed expectation"
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
end
