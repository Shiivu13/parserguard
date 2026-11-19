module Alerts
  # Slack incoming-webhook payload (also readable by any JSON webhook consumer).
  module SlackPayload
    EMOJI = { "broken" => ":rotating_light:", "major" => ":warning:", "minor" => ":large_yellow_circle:", "none" => ":white_check_mark:" }.freeze

    module_function

    def call(event, app_url: ENV["APP_URL"])
      fields = event.broken_fields.map { |f| "`#{f['contract']}##{f['field']}` (rate #{format('%.2f', f['rate'].to_f)})" }
      headline = "#{EMOJI[event.severity]} *#{event.severity.upcase}* layout drift on " \
                 "#{event.engine} #{event.locale}/#{event.device} (score #{format('%.3f', event.drift_score)})"
      lines = [ headline ]
      lines << "Broken: #{fields.join(', ')}" if fields.any?
      lines << "<#{app_url.chomp('/')}/drift_events/#{event.id}|Open in ParserGuard>" if app_url.present?

      {
        text: lines.first.gsub(/[*:]/, "").squish,
        blocks: [ { type: "section", text: { type: "mrkdwn", text: lines.join("\n") } } ],
        parserguard: {
          drift_event_id: event.id.to_s, severity: event.severity, drift_score: event.drift_score,
          engine: event.engine, broken_fields: event.broken_fields
        }
      }
    end
  end
end
