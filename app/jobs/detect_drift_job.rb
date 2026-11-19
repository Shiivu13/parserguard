# New snapshot -> drift event -> (healing per broken field, alert if actionable).
class DetectDriftJob < ApplicationJob
  queue_as :default

  def perform(snapshot_id)
    snapshot = find(Snapshot, snapshot_id)
    return if snapshot.nil? || snapshot.baseline

    result = Drift::Detector.call(snapshot)
    return if result.failure? || !result.meta[:created]

    event = result.value
    event.broken_fields.each do |broken|
      HealFieldJob.perform_later(broken["contract_id"], broken["field"], snapshot.id.to_s, event.id.to_s)
    end
    SendAlertJob.perform_later(event.id.to_s) if event.actionable?
  end
end
