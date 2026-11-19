module Api
  module V1
    class SnapshotsController < BaseController
      def index
        scope = Snapshot.light.recent
        scope = scope.where(engine: params[:engine]) if params[:engine].present?
        scope = scope.where(baseline: ActiveModel::Type::Boolean.new.cast(params[:baseline])) if params.key?(:baseline)
        render_page(scope) { |s| ApiSerializer.snapshot(s) }
      end

      def show
        include_html = params[:include].to_s.split(",").include?("html")
        scope = include_html ? Snapshot.all : Snapshot.light
        render json: { data: ApiSerializer.snapshot(find!(scope, params[:id]), include_html:) }
      end

      # Body: { engine, html } or { engine, url }; optional query, locale, device.
      def create
        html, source, source_ref = fetch_html
        return if performed?

        result = Ingestion::SnapshotCreator.call(
          html:, source:, source_ref:,
          engine: params.require(:engine), query: params[:query],
          locale: params[:locale].presence || "en-US", device: params[:device].presence || "desktop"
        )
        return render_result_error(result) if result.failure?

        duplicate = result.meta[:duplicate]
        after_create(result.value) unless duplicate
        render json: { data: ApiSerializer.snapshot(result.value), meta: { duplicate: } },
               status: duplicate ? :ok : :created
      end

      private

      def fetch_html
        if params[:html].present?
          [ params[:html], "api", nil ]
        elsif params[:url].present?
          fetched = Ingestion::UrlFetcher.call(params[:url])
          return render_result_error(fetched, status: :bad_gateway) if fetched.failure?

          [ fetched.value, "url", fetched.meta[:final_url] ]
        else
          render_error(:unprocessable_entity, "invalid_params", "provide html or url")
        end
      end

      # Hook for background processing (drift detection).
      def after_create(_snapshot); end
    end
  end
end
