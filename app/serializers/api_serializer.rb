# JSON shapes for API v1. One place so dashboard JSON and API stay consistent.
module ApiSerializer
  module_function

  def id(value) = value&.to_s

  def time(value) = value&.utc&.iso8601

  def snapshot(s, include_html: false)
    {
      id: id(s.id), engine: s.engine, query: s.query, locale: s.locale, device: s.device,
      source: s.source, source_ref: s.source_ref, version: s.version, baseline: s.baseline,
      byte_size: s.byte_size, sha256: s.sha256, captured_at: time(s.captured_at)
    }.tap { |h| h[:html] = s.html if include_html }
  end

  def contract(c)
    {
      id: id(c.id), key: c.key, engine: c.engine, result_type: c.result_type,
      scope_selector: c.scope_selector, container_selector: c.container_selector,
      min_extraction_rate: c.min_extraction_rate, version: c.version, active: c.active,
      fields: c.field_specs.map { |f| f.attributes.slice("name", "selector", "extract", "required", "value_type") },
      revisions: c.revisions.map do |r|
        { field: r.field_name, from: r.from_selector, to: r.to_selector, version: r.version,
          suggestion_id: id(r.suggestion_id), at: time(r.at) }
      end,
      updated_at: time(c.updated_at)
    }
  end

  def run(r, include_items: true)
    {
      id: id(r.id), contract_id: id(r.contract_id), snapshot_id: id(r.snapshot_id),
      contract_version: r.contract_version, status: r.status, extraction_rate: r.extraction_rate,
      container_count: r.container_count, field_stats: r.field_stats, duration_ms: r.duration_ms,
      created_at: time(r.created_at)
    }.tap do |h|
      if include_items
        h[:items] = r.items
        h[:validation_errors] = r.validation_errors
      end
    end
  end

  def drift_event(e)
    {
      id: id(e.id), engine: e.engine, locale: e.locale, device: e.device, severity: e.severity,
      drift_score: e.drift_score, tag_drift: e.tag_drift, class_drift: e.class_drift,
      baseline_snapshot_id: id(e.baseline_snapshot_id), candidate_snapshot_id: id(e.candidate_snapshot_id),
      broken_fields: e.broken_fields, added_paths: e.added_paths, removed_paths: e.removed_paths,
      alerted_at: time(e.alerted_at), acknowledged_at: time(e.acknowledged_at), created_at: time(e.created_at)
    }
  end

  def suggestion(s)
    {
      id: id(s.id), contract_id: id(s.contract_id), field: s.field_name, status: s.status,
      old_selector: s.old_selector, candidates: s.candidates, accepted_selector: s.accepted_selector,
      snapshot_id: id(s.snapshot_id), drift_event_id: id(s.drift_event_id),
      accepted_at: time(s.accepted_at), created_at: time(s.created_at)
    }
  end
end
