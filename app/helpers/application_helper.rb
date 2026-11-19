module ApplicationHelper
  def severity_badge(severity)
    tag.span(severity.to_s, class: "badge badge-#{severity.presence || 'none'}")
  end

  def status_badge(status)
    tag.span(status.to_s, class: "badge badge-status-#{status}")
  end

  def pct(value) = value.nil? ? "—" : "#{(value.to_f * 100).round(1)}%"

  def score(value) = value.nil? ? "—" : format("%.3f", value)

  def ago(time) = time ? "#{time_ago_in_words(time)} ago" : "—"

  # invert: true for metrics where higher is worse (drift score).
  def meter(value, label: nil, invert: false)
    v = value.to_f.clamp(0, 1)
    goodness = invert ? 1 - v : v
    tone = goodness >= 0.9 ? "good" : (goodness >= 0.5 ? "warn" : "bad")
    tag.span(class: "meter meter-#{tone}", title: label || pct(value), role: "img", "aria-label": label || pct(value)) do
      tag.span(class: "meter-fill", style: "width: #{(v * 100).round}%")
    end
  end

  def target_label(engine, locale, device) = "#{engine} · #{locale} · #{device}"
end
