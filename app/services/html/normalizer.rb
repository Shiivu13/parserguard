module Html
  # Parses raw HTML with the HTML5 parser (same tree browsers build) and drops
  # nodes that carry no layout signal: scripts, styles, inline SVG, comments.
  class Normalizer
    STRIP = %w[script style noscript svg template iframe link meta].freeze

    def self.call(html) = new(html).call

    def initialize(html)
      @html = html.to_s.dup.force_encoding(Encoding::UTF_8).scrub("")
    end

    def call
      doc = Nokogiri::HTML5(@html, max_errors: 0)
      doc.css(STRIP.join(",")).each(&:remove)
      doc.xpath("//comment()").each(&:remove)
      doc
    end
  end
end
