class HealFieldJob < ApplicationJob
  queue_as :default

  def perform(contract_id, field_name, snapshot_id, drift_event_id = nil)
    contract = find(ParserContract, contract_id)
    snapshot = find(Snapshot, snapshot_id)
    return unless contract && snapshot

    drift_event = drift_event_id && find(DriftEvent, drift_event_id)
    result = Healing::Healer.call(contract:, field_name:, snapshot:, drift_event:)
    Rails.logger.info("[heal] #{contract.key}##{field_name}: #{result.ok? ? "#{result.value.candidates.size} candidates" : result.error_message}")
  end
end
