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
