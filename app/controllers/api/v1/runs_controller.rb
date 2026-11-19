module Api
  module V1
    class RunsController < BaseController
      def index
        scope = ContractRun.recent
        scope = scope.where(contract_id: BSON::ObjectId.from_string(params[:contract_id])) if params[:contract_id].present?
        scope = scope.where(status: params[:status]) if params[:status].present?
        render_page(scope) { |r| ApiSerializer.run(r, include_items: false) }
      rescue BSON::Error::InvalidObjectId
        raise NotFound, "#{params[:contract_id]} is not a valid id"
      end

      def show
        render json: { data: ApiSerializer.run(find!(ContractRun, params[:id])) }
      end

      # POST /contracts/:contract_id/runs { snapshot_id }
      def create
        contract = find!(ParserContract, params[:contract_id])
        snapshot = find!(Snapshot, params.require(:snapshot_id))
        run = Contracts::Runner.call(contract, snapshot)
        render json: { data: ApiSerializer.run(run) }, status: :created
      end
    end
  end
end
