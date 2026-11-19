module Contracts
  # Limits on user-supplied CSS selectors. Selectors run against untrusted,
  # possibly hostile documents, so pathological ones (universal descendant
  # chains, deep :has nesting) are refused before they reach Nokogiri.
  module SelectorPolicy
    MAX_LENGTH = 200
    MAX_COMPOUNDS = 8

    module_function

    # Returns nil when acceptable, else a reason string.
    def violation(selector)
      sel = selector.to_s.strip
      return "is empty" if sel.empty?
      return "is longer than #{MAX_LENGTH} characters" if sel.length > MAX_LENGTH
      return "may not use the universal selector *" if sel.match?(/(?<![\[="'])\*(?![=\]])/)
      return "may not nest :has" if sel.scan(":has(").size > 1
      return "may not combine more than #{MAX_COMPOUNDS} compound selectors" if compounds(sel) > MAX_COMPOUNDS

      Nokogiri::HTML5.fragment("<p></p>").css(sel)
      nil
    rescue Nokogiri::CSS::SyntaxError, Nokogiri::XML::XPath::SyntaxError
      "is not valid CSS"
    end

    def valid?(selector) = violation(selector).nil?

    def compounds(sel)
      sel.split(",").sum { |part| part.strip.split(/\s*[>+~]\s*|\s+/).reject(&:empty?).size }
    end
  end
end
