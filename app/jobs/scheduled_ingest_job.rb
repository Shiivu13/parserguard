# Cron entry point (config/schedule.yml). Fetches each watched target from
# config/parserguard.yml `watch:` and hands new snapshots to drift detection.
class ScheduledIngestJob < ApplicationJob
  queue_as :default

  def perform
    Array(Rails.application.config.parserguard[:watch]).each do |target|
      ingest(target)
    rescue StandardError => e
      Rails.logger.error("[ingest] #{target.inspect} failed: #{e.class}: #{e.message}")
    end
  end

  private

  def ingest(target)
    fetched = fetch(target)
    return Rails.logger.warn("[ingest] #{target[:engine]} #{target[:query] || target[:url]}: #{fetched.error_message}") if fetched.failure?

    created = Ingestion::SnapshotCreator.call(
      html: fetched.value, engine: target.fetch(:engine), query: target[:query],
      source: target[:url] ? "url" : "serpapi", charset: fetched.meta[:charset],
      source_ref: fetched.meta[:source_ref] || fetched.meta[:final_url],
      locale: target[:locale] || "en-US", device: target[:device] || "desktop"
    )
    return unless created.ok? && !created.meta[:duplicate]

    DetectDriftJob.perform_later(created.value.id.to_s)
  end

  def fetch(target)
    if target[:url]
      Ingestion::UrlFetcher.call(target[:url])
    else
      Ingestion::SerpApiFetcher.call(query: target.fetch(:query), engine: target.fetch(:engine), location: target[:location])
    end
  end
end
