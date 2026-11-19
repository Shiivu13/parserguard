class SnapshotsController < ApplicationController
  PER_PAGE = 30

  def index
    @engine = params[:engine].presence
    scope = Snapshot.light.recent
    scope = scope.where(engine: @engine) if @engine
    @snapshots = scope.limit(PER_PAGE).to_a
  end

  def show
    @snapshot = find_or_404(Snapshot, params[:id])
    @runs = ContractRun.where(snapshot_id: @snapshot.id).recent.limit(10).to_a
    @event = DriftEvent.where(candidate_snapshot_id: @snapshot.id).first
  end

  def promote
    snapshot = find_or_404(Snapshot, params[:id])
    snapshot.promote_to_baseline!
    redirect_to snapshot_path(snapshot), notice: "#{snapshot.label} is now the baseline."
  end
end
