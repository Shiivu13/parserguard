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
      # Validated before anything is written; concurrent edits retry on version.
      def update
        contract = find!(ParserContract, params[:id])
        scalars = contract_params.except(:engine, :result_type).to_h
        specs = field_specs_param.map(&:as_document) if params.key?(:fields)

        updated = ParserContract.change!(contract.id) do |doc|
          before = selector_snapshot(doc)
          scalars.each { |name, value| doc[name] = ParserContract.fields[name].mongoize(value) }
          doc["field_specs"] = specs if specs
          { bump: selector_snapshot(doc) != before }
        end

        if updated.errors.empty?
          render json: { data: ApiSerializer.contract(updated) }
        else
          render_error(:unprocessable_entity, "invalid_contract", updated.errors.full_messages.to_sentence)
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

      def selector_snapshot(doc)
        [ doc["scope_selector"], doc["container_selector"], Array(doc["field_specs"]).map { |f| f.values_at("name", "selector", "extract") } ]
      end
    end
  end
end
