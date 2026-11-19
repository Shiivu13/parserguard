class ContractsController < ApplicationController
  def index
    @contracts = ParserContract.order_by(engine: :asc, result_type: :asc).to_a
  end

  def show
    @contract = find_or_404(ParserContract, params[:id])
    @runs = ContractRun.where(contract_id: @contract.id).recent.limit(15).to_a
    @suggestions = SelectorSuggestion.where(contract_id: @contract.id).recent.limit(10).to_a
  end

  # Re-run on a snapshot from the dashboard (synchronous: runs take milliseconds).
  def run
    contract = find_or_404(ParserContract, params[:id])
    snapshot = find_or_404(Snapshot, params.require(:snapshot_id))
    run = Contracts::Runner.call(contract, snapshot)
    redirect_to contract_path(contract), notice: "Run #{run.status}: #{(run.extraction_rate * 100).round}% on #{snapshot.label}."
  end
end
