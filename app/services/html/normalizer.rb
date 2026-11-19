module Html
  # Parses raw HTML with the HTML5 parser (same tree browsers build) and drops
  # nodes that carry no layout signal: scripts, styles, inline SVG, comments.
  class Normalizer
    STRIP = %w[script style noscript svg template iframe link meta].freeze
    # Real SERPs nest ~40 levels; hostile pages nest thousands to slow selectors down.
    MAX_TREE_DEPTH = 128

    class TooDeep < StandardError; end

    def self.call(html) = new(html).call

    def initialize(html)
      @html = html.to_s.dup.force_encoding(::Encoding::UTF_8).scrub("\uFFFD")
    end

    def call
      doc = Nokogiri::HTML5(@html, max_errors: 0, max_tree_depth: MAX_TREE_DEPTH)
      doc.css(STRIP.join(",")).each(&:remove)
      doc.xpath("//comment()").each(&:remove)
      doc
    rescue ArgumentError => e
      raise TooDeep, "document nests deeper than #{MAX_TREE_DEPTH} levels" if e.message.include?("depth")

      raise
    end
  end
end
