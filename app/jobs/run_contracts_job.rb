# Re-runs a contract after its selectors changed. Fields that still fail and
# have no pending suggestion get a new healing pass, so a structural change
# heals step by step: container first, then the fields inside it.
class RunContractsJob < ApplicationJob
  queue_as :default

  def perform(contract_id, snapshot_id)
    contract = find(ParserContract, contract_id)
    snapshot = find(Snapshot, snapshot_id)
    return unless contract && snapshot

    run = Contracts::Runner.call(contract, snapshot)
    return if run.passed? || snapshot.baseline

    failing = run.container_count.zero? ? [ ParserContract::CONTAINER_FIELD ] : run.failing_fields(contract.min_extraction_rate)
    failing.each do |field|
      next if SelectorSuggestion.pending.where(contract_id: contract.id, field_name: field).exists?

      HealFieldJob.perform_later(contract.id.to_s, field, snapshot.id.to_s)
    end
  end
end
