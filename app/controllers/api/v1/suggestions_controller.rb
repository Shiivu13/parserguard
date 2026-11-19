module Api
  module V1
    class SuggestionsController < BaseController
      def index
        scope = SelectorSuggestion.recent
        scope = scope.where(status: params[:status]) if params[:status].present?
        render_page(scope) { |s| ApiSerializer.suggestion(s) }
      end

      def show
        render json: { data: ApiSerializer.suggestion(find!(SelectorSuggestion, params[:id])) }
      end

      # POST /suggestions/:id/accept { selector? } (defaults to the top candidate)
      def accept
        suggestion = find!(SelectorSuggestion, params[:id])
        result = Healing::SuggestionAcceptor.call(suggestion, selector: params[:selector])
        return render_result_error(result, status: :conflict) if result.failure? && !suggestion.pending?
        return render_result_error(result) if result.failure?

        after_accept(suggestion)
        render json: { data: ApiSerializer.suggestion(suggestion.reload), contract: ApiSerializer.contract(result.value) }
      end

      def reject
        suggestion = find!(SelectorSuggestion, params[:id])
        return render_error(:conflict, "conflict", "suggestion is already #{suggestion.status}") unless suggestion.pending?

        suggestion.update!(status: "rejected")
        render json: { data: ApiSerializer.suggestion(suggestion) }
      end

      private

      def after_accept(suggestion)
        RunContractsJob.perform_later(suggestion.contract_id.to_s, suggestion.snapshot_id.to_s) if suggestion.snapshot_id
      end
    end
  end
end
