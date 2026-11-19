module Alerts
  # POSTs a drift alert to the configured webhook. 5xx/timeouts raise
  # DeliveryError so the job retries; 4xx is a config problem and does not.
  class WebhookNotifier
    class DeliveryError < StandardError; end

    def self.call(event, **) = new(**).call(event)

    def initialize(url: Rails.application.config.parserguard.dig(:alerts, :webhook_url), connection: nil)
      @url = url
      @connection = connection || Faraday.new { |f| f.options.timeout = 10 }
    end

    def call(event)
      return Result.failure("no webhook configured", skipped: true) if @url.blank?

      response = @connection.post(@url, SlackPayload.call(event).to_json, "Content-Type" => "application/json")
      raise DeliveryError, "webhook HTTP #{response.status}" if response.status >= 500
      return Result.failure("webhook HTTP #{response.status}") unless response.success?

      Result.success(response.status)
    rescue Faraday::TimeoutError, Faraday::ConnectionFailed => e
      raise DeliveryError, "webhook unreachable: #{e.class.name.demodulize}"
    end
  end
end
