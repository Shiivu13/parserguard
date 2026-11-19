module ApplicationHelper
  def nav_link(name_or_path, path = nil, controller:, &block)
    path, name = block ? [ name_or_path, nil ] : [ path, name_or_path ]
    active = controller_name == controller
    link_to(path, class: ("active" if active), "aria-current": ("page" if active)) { block ? capture(&block) : name }
  end

  def pending_suggestions_count
    @pending_suggestions_count ||= SelectorSuggestion.pending.count
  end

  def page_head(title, subtitle = nil, &actions)
    content_for(:title, title) unless content_for?(:title)
    tag.div(class: "page-head") do
      heading = tag.div { tag.h1(title) + (subtitle ? tag.p(subtitle, class: "muted") : "".html_safe) }
      heading + (actions ? tag.div(capture(&actions), class: "page-actions") : "".html_safe)
    end
  end

  def severity_badge(severity)
    tag.span(severity.presence || "none", class: "badge badge-#{severity.presence || 'none'}")
  end

  def status_badge(status)
    tag.span(status.to_s, class: "badge badge-status-#{status}")
  end

  def selector(sel, old: false)
    tag.code(sel, class: [ "sel", ("sel-old" if old) ])
  end

  def pct(value) = value.nil? ? "—" : "#{(value.to_f * 100).round(1)}%"

  def score(value) = value.nil? ? "—" : format("%.3f", value)

  def ago(time) = time ? "#{time_ago_in_words(time)} ago" : "—"

  # Horizontal bar. invert: true for metrics where higher is worse (drift score).
  def meter(value, invert: false)
    v = value.to_f.clamp(0, 1)
    goodness = invert ? 1 - v : v
    tone = goodness >= 0.9 ? "good" : (goodness >= 0.5 ? "warn" : "bad")
    tag.span(class: "meter meter-#{tone}", "aria-hidden": true) do
      tag.span(class: "meter-fill", style: "width: #{(v * 100).round}%")
    end
  end

  # Meter plus its number, e.g. extraction rate "100.0%" or drift "0.349".
  def metric(value, invert: false, as: :pct)
    tag.span(class: "metric") { meter(value, invert:) + (as == :pct ? pct(value) : score(value)) }
  end

  # Tiny line chart of values in 0..1 (drift history), newest on the right.
  def sparkline(values, width: 120, height: 32)
    return "" if values.size < 2

    step = width.to_f / (values.size - 1)
    points = values.each_with_index.map do |v, i|
      [ (i * step).round(1), (height - 3 - v.to_f.clamp(0, 1) * (height - 6)).round(1) ]
    end
    last_x, last_y = points.last
    tag.svg(class: "spark", width:, height:, viewBox: "0 0 #{width} #{height}", role: "img",
            "aria-label": "Drift score over the last #{values.size} comparisons") do
      tag.polyline(points: points.map { |p| p.join(",") }.join(" "), fill: "none") +
        tag.circle(cx: last_x, cy: last_y, r: 2.5)
    end
  end

  def target_label(engine, locale, device) = "#{engine} · #{locale} · #{device}"
end
