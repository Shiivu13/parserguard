module Ingestion
  # Persists one HTML capture as a Snapshot:
  # - dedupes on sha256 (same bytes => same snapshot, no new version)
  # - assigns version = max + 1 per (engine, locale, device), retrying on races
  # - precomputes structure histograms
  # - first snapshot of a target becomes its baseline
  class SnapshotCreator
    DUPLICATE_KEY = 11_000
    MAX_ATTEMPTS = 3

    def self.call(**) = new(**).call

    def initialize(html:, engine:, source:, query: nil, locale: "en-US", device: "desktop",
                   source_ref: nil, captured_at: nil)
      @html = html.to_s
      @attrs = { engine:, source:, query:, locale:, device:, source_ref:,
                 captured_at: captured_at || Time.current }
    end

    def call
      return Result.failure("html is empty") if @html.strip.empty?

      max = Rails.application.config.parserguard.dig(:ingestion, :max_bytes)
      return Result.failure("html exceeds #{max} bytes") if max && @html.bytesize > max

      existing = find_duplicate
      return Result.success(existing, duplicate: true) if existing

      signature = Html::StructureSignature.call(Html::Normalizer.call(@html))
      snapshot = persist(signature)
      return Result.failure(snapshot.errors.full_messages) unless snapshot.persisted?

      promote_if_first(snapshot)
      Result.success(snapshot, duplicate: false)
    rescue Mongo::Error::OperationFailure => e
      raise unless e.code == DUPLICATE_KEY

      existing = find_duplicate
      existing ? Result.success(existing, duplicate: true) : raise
    end

    private

    def find_duplicate = Snapshot.light.where(sha256: Snapshot.digest(@html)).first

    def persist(signature)
      attempts = 0
      begin
        attempts += 1
        snapshot = Snapshot.new(@attrs.merge(signature.to_h))
        snapshot.html = @html
        snapshot.version = Snapshot.next_version(*snapshot.target)
        snapshot.save
        snapshot
      rescue Mongo::Error::OperationFailure => e
        # Another writer took this version number; recompute and retry.
        raise unless e.code == DUPLICATE_KEY && attempts < MAX_ATTEMPTS && !find_duplicate

        retry
      end
    end

    def promote_if_first(snapshot)
      return if Snapshot.baseline_for(*snapshot.target)

      snapshot.promote_to_baseline!
    end
  end
end
