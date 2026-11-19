class DashboardController < ApplicationController
  Target = Data.define(:engine, :locale, :device, :snapshot_count, :last_captured_at, :baseline, :latest, :latest_event)

  def index
    @targets = targets
    @contracts = ParserContract.order_by(engine: :asc, result_type: :asc).to_a
    @latest_runs = @contracts.to_h { |c| [ c.id, ContractRun.where(contract_id: c.id).recent.first ] }
    @pending_suggestions = SelectorSuggestion.pending.count
    @open_events = DriftEvent.actionable.where(acknowledged_at: nil).count
    @recent_events = DriftEvent.recent.limit(8).to_a
  end

  private

  # One card per (engine, locale, device), built from a single aggregation.
  def targets
    groups = Snapshot.collection.aggregate([
      { "$group" => {
        "_id" => { "engine" => "$engine", "locale" => "$locale", "device" => "$device" },
        "count" => { "$sum" => 1 },
        "last" => { "$max" => "$captured_at" }
      } },
      { "$sort" => { "_id.engine" => 1, "_id.locale" => 1, "_id.device" => 1 } }
    ])

    groups.map do |g|
      key = g["_id"]
      scope = Snapshot.light.for_target(key["engine"], key["locale"], key["device"])
      Target.new(
        engine: key["engine"], locale: key["locale"], device: key["device"],
        snapshot_count: g["count"], last_captured_at: g["last"],
        baseline: scope.where(baseline: true).first,
        latest: scope.recent.first,
        latest_event: DriftEvent.where(engine: key["engine"], locale: key["locale"], device: key["device"]).recent.first
      )
    end
  end
end
