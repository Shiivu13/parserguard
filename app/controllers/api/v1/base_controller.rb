module Api
  module V1
    # Auth: X-Api-Key header (only its SHA256 is stored server-side).
    # Errors: { "error": { "code": "...", "message": "..." } }
    class BaseController < ActionController::API
      MAX_PER_PAGE = 100

      class NotFound < StandardError; end

      before_action :authenticate!

      rescue_from NotFound, BSON::Error::InvalidObjectId do |e|
        render_error(:not_found, "not_found", e.message.presence || "not found")
      end
      rescue_from ActionController::ParameterMissing do |e|
        render_error(:unprocessable_entity, "invalid_params", e.message)
      end

      private

      attr_reader :current_api_key

      def authenticate!
        @current_api_key = ApiKey.authenticate(request.headers["X-Api-Key"])
        render_error(:unauthorized, "unauthorized", "missing or invalid X-Api-Key") unless current_api_key
      end

      def find!(scope, id)
        scope.where(_id: BSON::ObjectId.from_string(id.to_s)).first || raise(NotFound, "#{scope.name.underscore.humanize} #{id} not found")
      rescue BSON::Error::InvalidObjectId
        raise NotFound, "#{id} is not a valid id"
      end

      def paginate(scope)
        page = [ params.fetch(:page, 1).to_i, 1 ].max
        per = params.fetch(:per, 25).to_i.clamp(1, MAX_PER_PAGE)
        records = scope.skip((page - 1) * per).limit(per).to_a
        [ records, { page:, per:, total: scope.count } ]
      end

      def render_page(scope)
        records, meta = paginate(scope)
        render json: { data: records.map { |r| yield r }, meta: }
      end

      def render_error(status, code, message, details: nil)
        body = { error: { code:, message: } }
        body[:error][:details] = details if details
        render json: body, status:
      end

      def render_result_error(result, status: :unprocessable_entity)
        render_error(status, "unprocessable", result.error_message, details: result.errors)
      end
    end
  end
end
