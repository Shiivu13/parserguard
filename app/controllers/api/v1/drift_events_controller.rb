module Api
  module V1
    class DriftEventsController < BaseController
      def index
        scope = DriftEvent.recent
        scope = scope.where(engine: params[:engine]) if params[:engine].present?
        scope = scope.where(:severity.in => params[:severity].to_s.split(",")) if params[:severity].present?
        render_page(scope) { |e| ApiSerializer.drift_event(e) }
      end

      def show
        render json: { data: ApiSerializer.drift_event(find!(DriftEvent, params[:id])) }
      end

      def acknowledge
        event = find!(DriftEvent, params[:id])
        event.acknowledge! unless event.acknowledged_at
        render json: { data: ApiSerializer.drift_event(event) }
      end
    end
  end
end
