module Contracts
  # Pulls one raw value out of a container node.
  module FieldExtractor
    module_function

    # Returns [raw_value, node] or [nil, nil]. Invalid CSS counts as "not found".
    def call(container, selector:, extract: "text")
      node = container.at_css(selector)
      return [ nil, nil ] unless node

      value = extract.to_s == "text" || extract.blank? ? node.text : node[extract]
      [ value, node ]
    rescue Nokogiri::CSS::SyntaxError, Nokogiri::XML::XPath::SyntaxError
      [ nil, nil ]
    end

    # All values a selector yields inside one container (used to score candidates).
    def all(container, selector:, extract: "text")
      container.css(selector).map { |n| extract.to_s == "text" ? n.text : n[extract] }.compact
    rescue Nokogiri::CSS::SyntaxError, Nokogiri::XML::XPath::SyntaxError
      []
    end
  end
end
