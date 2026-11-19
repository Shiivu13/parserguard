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
