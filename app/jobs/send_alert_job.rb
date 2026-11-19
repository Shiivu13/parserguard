class SendAlertJob < ApplicationJob
  queue_as :alerts
  retry_on Alerts::WebhookNotifier::DeliveryError, wait: :polynomially_longer, attempts: 3

  def perform(drift_event_id)
    event = find(DriftEvent, drift_event_id)
    return if event.nil? || event.alerted_at

    result = Alerts::WebhookNotifier.call(event)
    # Mark only after a delivery (or when no webhook is configured) so retries are safe.
    event.set(alerted_at: Time.current) if result.ok? || result.meta[:skipped]
  end
end
