class DriftEventsController < ApplicationController
  def index
    @events = DriftEvent.recent.limit(100).to_a
    @snapshots = Snapshot.light.in(_id: @events.flat_map { |e| [ e.baseline_snapshot_id, e.candidate_snapshot_id ] }.uniq).index_by(&:id)
  end

  def show
    @event = find_or_404(DriftEvent, params[:id])
    @baseline = Snapshot.light.find(@event.baseline_snapshot_id)
    @candidate = Snapshot.light.find(@event.candidate_snapshot_id)
    @suggestions = SelectorSuggestion.where(drift_event_id: @event.id).recent.to_a
    @runs = ContractRun.where(snapshot_id: @candidate.id).recent.limit(5).to_a
  end

  def acknowledge
    event = find_or_404(DriftEvent, params[:id])
    event.acknowledge! unless event.acknowledged_at
    redirect_to drift_event_path(event), notice: "Acknowledged."
  end
end
