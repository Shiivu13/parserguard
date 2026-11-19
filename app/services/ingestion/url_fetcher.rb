require "ipaddr"
require "resolv"

module Ingestion
  # Fetches a URL with SSRF guards:
  # - http/https only
  # - every hop's host must resolve to public IPs (redirects re-checked)
  # - timeout and response size cap
  class UrlFetcher
    MAX_REDIRECTS = 3
    BLOCKED_RANGES = %w[
      0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12
      192.0.0.0/24 192.168.0.0/16 198.18.0.0/15 224.0.0.0/4 240.0.0.0/4
      ::1/128 fc00::/7 fe80::/10 ::ffff:0:0/96
    ].map { |r| IPAddr.new(r) }.freeze

    DEFAULT_RESOLVER = ->(host) { Resolv.getaddresses(host) }

    def self.call(url, **) = new(**).call(url)

    def initialize(resolver: DEFAULT_RESOLVER, connection: nil)
      config = Rails.application.config.parserguard[:ingestion]
      @resolver = resolver
      @max_bytes = config[:max_bytes]
      @connection = connection || Faraday.new do |f|
        f.options.timeout = config[:timeout]
        f.options.open_timeout = config[:timeout]
        f.headers["User-Agent"] = "ParserGuard/1.0 (+layout drift monitor)"
      end
    end

    def call(url)
      current = url
      (MAX_REDIRECTS + 1).times do
        uri = safe_uri(current)
        return uri if uri.is_a?(Result)

        response = @connection.get(uri.to_s)
        if response.status.between?(300, 399) && response.headers["location"]
          current = URI.join(uri, response.headers["location"]).to_s
          next
        end
        return Result.failure("HTTP #{response.status}") unless response.success?

        body = response.body.to_s
        return Result.failure("response exceeds #{@max_bytes} bytes") if body.bytesize > @max_bytes

        return Result.success(body, final_url: uri.to_s)
      end
      Result.failure("too many redirects")
    rescue Faraday::TimeoutError
      Result.failure("timeout")
    rescue Faraday::ConnectionFailed => e
      # Net::OpenTimeout surfaces as ConnectionFailed, not TimeoutError.
      return Result.failure("timeout") if e.wrapped_exception.is_a?(Timeout::Error)

      Result.failure("connection failed: #{e.message}")
    end

    private

    def safe_uri(raw)
      uri = URI.parse(raw.to_s)
      return Result.failure("only http/https URLs are allowed") unless %w[http https].include?(uri.scheme)
      return Result.failure("URL has no host") if uri.host.blank?

      addresses = @resolver.call(uri.host)
      return Result.failure("host does not resolve") if addresses.empty?
      return Result.failure("host resolves to a private address") if addresses.any? { |a| private_ip?(a) }

      uri
    rescue URI::InvalidURIError
      Result.failure("invalid URL")
    end

    def private_ip?(address)
      ip = IPAddr.new(address)
      BLOCKED_RANGES.any? { |range| range.family == ip.family && range.include?(ip) }
    rescue IPAddr::InvalidAddressError
      true
    end
  end
end
