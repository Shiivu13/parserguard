class DashboardController < ApplicationController
  HISTORY = 12

  Target = Data.define(:engine, :locale, :device, :snapshot_count, :last_captured_at, :baseline, :latest_event, :history)

  def index
    @targets = targets
    @contracts = ParserContract.order_by(engine: :asc, result_type: :asc).to_a
    @latest_runs = @contracts.to_h { |c| [ c.id, ContractRun.where(contract_id: c.id).recent.first ] }
    @review_queue = SelectorSuggestion.pending.recent.limit(5).to_a
    @queue_contracts = ParserContract.in(_id: @review_queue.map(&:contract_id)).index_by(&:id)
    @open_events = DriftEvent.actionable.where(acknowledged_at: nil).count
    @recent_events = DriftEvent.recent.limit(8).to_a
  end

  private

  # One card per (engine, locale, device), grouped in a single aggregation.
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
      key = g["_id"].to_h.symbolize_keys
      events = DriftEvent.where(key).recent.limit(HISTORY).to_a
      Target.new(
        **key, snapshot_count: g["count"], last_captured_at: g["last"],
        baseline: Snapshot.baseline_for(key[:engine], key[:locale], key[:device]),
        latest_event: events.first,
        history: events.reverse.map(&:drift_score)
      )
    end
  end
end
