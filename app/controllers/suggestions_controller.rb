class SuggestionsController < ApplicationController
  def index
    @status = params[:status].presence_in(SelectorSuggestion::STATUSES) || "pending"
    @suggestions = SelectorSuggestion.where(status: @status).recent.limit(50).to_a
    @contracts = ParserContract.in(_id: @suggestions.map(&:contract_id).uniq).index_by(&:id)
  end

  # Side by side: what the old selector extracted on the baseline vs what
  # each candidate extracts on the new snapshot.
  def show
    @suggestion = find_or_404(SelectorSuggestion, params[:id])
    @contract = @suggestion.contract
    @snapshot = @suggestion.snapshot_id && Snapshot.light.find(@suggestion.snapshot_id)
    baseline = @snapshot && Snapshot.baseline_for(*@snapshot.target)
    @baseline_run = baseline && ContractRun.where(contract_id: @contract.id, snapshot_id: baseline.id, status: "passed").recent.first
  end

  # JSON for the Stimulus accept button; HTML redirect as a no-JS fallback.
  def accept
    suggestion = find_or_404(SelectorSuggestion, params[:id])
    result = Healing::SuggestionAcceptor.call(suggestion, selector: params[:selector])

    if result.ok? && suggestion.snapshot_id
      RunContractsJob.perform_later(suggestion.contract_id.to_s, suggestion.snapshot_id.to_s)
    end

    respond_to do |format|
      format.json do
        if result.ok?
          render json: { status: "accepted", selector: suggestion.reload.accepted_selector, contract_version: result.value.version }
        else
          render json: { error: result.error_message }, status: :unprocessable_entity
        end
      end
      format.html do
        flash[result.ok? ? :notice : :alert] = result.ok? ? "Applied #{suggestion.reload.accepted_selector}" : result.error_message
        redirect_to suggestion_path(suggestion)
      end
    end
  end

  def reject
    suggestion = find_or_404(SelectorSuggestion, params[:id])
    suggestion.update!(status: "rejected") if suggestion.pending?
    redirect_to suggestion_path(suggestion), notice: "Rejected."
  end
end
