module Api
  module V1
    class ContractsController < BaseController
      def index
        scope = ParserContract.order_by(engine: :asc, result_type: :asc)
        scope = scope.where(engine: params[:engine]) if params[:engine].present?
        render_page(scope) { |c| ApiSerializer.contract(c) }
      end

      def show
        render json: { data: ApiSerializer.contract(find!(ParserContract, params[:id])) }
      end

      def create
        contract = ParserContract.new(contract_params)
        contract.field_specs = field_specs_param if params.key?(:fields)
        if contract.save
          render json: { data: ApiSerializer.contract(contract) }, status: :created
        else
          render_error(:unprocessable_entity, "invalid_contract", contract.errors.full_messages.to_sentence)
        end
      end

      # Selector edits bump the version so runs stay attributable to a contract revision.
      def update
        contract = find!(ParserContract, params[:id])
        before = selector_snapshot(contract)
        contract.assign_attributes(contract_params.except(:engine, :result_type))
        contract.field_specs = field_specs_param if params.key?(:fields)
        contract.version += 1 if selector_snapshot(contract) != before

        if contract.save
          render json: { data: ApiSerializer.contract(contract) }
        else
          render_error(:unprocessable_entity, "invalid_contract", contract.errors.full_messages.to_sentence)
        end
      end

      # POST /contracts/:id/heal { field, snapshot_id }
      def heal
        contract = find!(ParserContract, params[:id])
        snapshot = find!(Snapshot, params.require(:snapshot_id))
        result = Healing::Healer.call(contract:, field_name: params.require(:field), snapshot:)
        return render_result_error(result) if result.failure?

        render json: { data: ApiSerializer.suggestion(result.value) }, status: result.meta[:created] ? :created : :ok
      end

      private

      def contract_params
        params.permit(:engine, :result_type, :scope_selector, :container_selector, :min_extraction_rate, :active)
      end

      def field_specs_param
        Array(params.require(:fields)).map do |f|
          FieldSpec.new(f.permit(:name, :selector, :extract, :required, :value_type).to_h)
        end
      end

      def selector_snapshot(contract)
        [ contract.scope_selector, contract.container_selector, contract.field_specs.map { |f| [ f.name, f.selector, f.extract ] } ]
      end
    end
  end
end
