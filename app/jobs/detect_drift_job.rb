# New snapshot -> drift event -> (healing per broken field, alert if actionable).
#
# Safe to retry at any point: the event is unique per snapshot pair, healing
# is skipped for fields that already have a suggestion for this event, and
# SendAlertJob only sends while alerted_at is nil.
class DetectDriftJob < ApplicationJob
  queue_as :default

  def perform(snapshot_id)
    snapshot = find(Snapshot, snapshot_id)
    return if snapshot.nil? || snapshot.baseline

    result = Drift::Detector.call(snapshot)
    return if result.failure?

    event = result.value
    healed = SelectorSuggestion.where(drift_event_id: event.id).pluck(:field_name).to_set
    event.broken_fields.each do |broken|
      next if healed.include?(broken["field"])

      HealFieldJob.perform_later(broken["contract_id"], broken["field"], snapshot.id.to_s, event.id.to_s)
    end
    SendAlertJob.perform_later(event.id.to_s) if event.actionable? && event.alerted_at.nil?
  end
end
