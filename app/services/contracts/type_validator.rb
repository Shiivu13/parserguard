module Contracts
  # Validates and normalizes one extracted value.
  #   TypeValidator.call("/url?q=https://x.com/&sa=U", "url") #=> [true, "https://x.com/"]
  module TypeValidator
    DEFAULT_BASE = "https://www.google.com".freeze

    module_function

    # Returns [valid, normalized_value].
    def call(value, type, base_url: DEFAULT_BASE)
      return [ false, nil ] if value.nil?

      case type.to_s
      when "string" then string(value)
      when "url" then url(value, base_url)
      when "integer" then integer(value)
      else [ false, nil ]
      end
    end

    def string(value)
      text = value.to_s.squish
      [ text.present?, text.presence ]
    end

    # First number in the text: "About 1,230 results (0.45 seconds)" -> 1230.
    # Decimals ("4.5") are not integers.
    def integer(value)
      match = value.to_s.match(/(?<![\d.])(-?\d{1,3}(?:[,\u00a0 ]\d{3})+|-?\d+)(\.\d+)?/)
      return [ false, nil ] if match.nil? || match[2]

      [ true, match[1].gsub(/[,\u00a0 ]/, "").to_i ]
    end

    def url(value, base_url)
      raw = value.to_s.strip
      return [ false, nil ] if raw.empty?

      uri = URI.join(base_url, raw)
      # Google wraps outbound links as /url?q=<target>&sa=... (only unwrap Google's own).
      if uri.path == "/url" && uri.query && google_host?(uri.host, raw)
        target = URI.decode_www_form(uri.query).to_h["q"]
        uri = URI.parse(target) if target
      end
      ok = %w[http https].include?(uri.scheme) && uri.host.present?
      [ ok, ok ? uri.to_s : nil ]
    rescue URI::Error, ArgumentError
      [ false, nil ]
    end

    def google_host?(host, raw)
      raw.start_with?("/") || host.to_s.match?(/(\A|\.)google\.[a-z.]+\z/)
    end
  end
end
