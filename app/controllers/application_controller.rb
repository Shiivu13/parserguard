class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  before_action :require_dashboard_auth

  private

  # HTTP basic auth from DASHBOARD_USER / DASHBOARD_PASSWORD.
  # Production refuses to serve the dashboard without a password configured.
  def require_dashboard_auth
    password = ENV["DASHBOARD_PASSWORD"]
    if password.blank?
      head :service_unavailable if Rails.env.production?
      return
    end

    authenticate_or_request_with_http_basic("ParserGuard") do |user, pass|
      ActiveSupport::SecurityUtils.secure_compare(user, ENV.fetch("DASHBOARD_USER", "admin")) &
        ActiveSupport::SecurityUtils.secure_compare(pass, password)
    end
  end

  def find_or_404(scope, id)
    scope.where(_id: BSON::ObjectId.from_string(id.to_s)).first || raise(ActionController::RoutingError, "not found")
  rescue BSON::Error::InvalidObjectId
    raise ActionController::RoutingError, "not found"
  end
end
