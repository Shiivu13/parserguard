require "ipaddr"
require "net/http"
require "resolv"

module Ingestion
  # Fetches a URL with SSRF guards:
  # - http/https only
  # - the host is resolved once, every address must be public, and the
  #   connection is pinned to that vetted IP (no second DNS lookup, so DNS
  #   rebinding cannot swap in an internal address)
  # - every redirect hop is re-vetted and re-pinned
  # - body is streamed and aborted past max_bytes; no transparent gzip
  #   decoding (no decompression bombs); total deadline across all hops
  # - errors returned to callers are generic; details go to the log
  class UrlFetcher
    MAX_REDIRECTS = 3
    USER_AGENT = "ParserGuard/1.0 (+layout drift monitor)".freeze

    # Non-global ranges. IPv6 forms that embed or route to IPv4 (mapped,
    # compatible, NAT64, 6to4, Teredo) are blocked wholesale.
    BLOCKED_RANGES = %w[
      0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12
      192.0.0.0/24 192.0.2.0/24 192.88.99.0/24 192.168.0.0/16 198.18.0.0/15
      198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4
      ::/96 ::ffff:0:0/96 64:ff9b::/96 64:ff9b:1::/48 100::/64 2001::/32 2001:db8::/32
      2002::/16 fc00::/7 fe80::/10 fec0::/10 ff00::/8
    ].map { |r| IPAddr.new(r) }.freeze

    DEFAULT_RESOLVER = ->(host) { Resolv.getaddresses(host) }

    class TooLarge < StandardError; end
    class DeadlineExceeded < StandardError; end

    def self.call(url, **) = new(**).call(url)

    def self.blocked_ip?(address)
      ip = IPAddr.new(address.to_s)
      BLOCKED_RANGES.any? { |range| range.family == ip.family && range.include?(ip) }
    rescue IPAddr::InvalidAddressError
      true
    end

    def initialize(resolver: DEFAULT_RESOLVER, max_bytes: nil, timeout: nil, total_timeout: nil)
      config = Rails.application.config.parserguard[:ingestion]
      @resolver = resolver
      @max_bytes = max_bytes || config[:max_bytes]
      @timeout = timeout || config[:timeout]
      @total_timeout = total_timeout || @timeout * 3
    end

    def call(url)
      @deadline = now + @total_timeout
      current = url
      (MAX_REDIRECTS + 1).times do
        vetted = vet(current)
        return vetted if vetted.is_a?(Result)

        uri, ip = vetted
        kind, value = fetch(uri, ip)
        case kind
        when :redirect then current = URI.join(uri, value).to_s
        when :ok then return Result.success(value, final_url: uri.to_s, charset: @charset)
        else return Result.failure(value)
        end
      end
      Result.failure("too many redirects")
    rescue TooLarge
      Result.failure("response exceeds #{@max_bytes} bytes")
    rescue DeadlineExceeded, Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, Timeout::Error
      Result.failure("timeout")
    rescue SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError, Net::HTTPBadResponse => e
      Rails.logger.info("[url_fetcher] #{url}: #{e.class}: #{e.message}")
      Result.failure("connection failed")
    rescue URI::Error
      Result.failure("invalid URL")
    end

    private

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # Returns [uri, pinned_ip] or a failed Result.
    def vet(raw)
      uri = URI.parse(raw.to_s)
      return Result.failure("only http/https URLs are allowed") unless %w[http https].include?(uri.scheme)

      host = uri.hostname
      return Result.failure("URL has no host") if host.blank?

      addresses = @resolver.call(host)
      return Result.failure("host does not resolve") if addresses.empty?
      return Result.failure("host resolves to a private address") if addresses.any? { |a| self.class.blocked_ip?(a) }

      [ uri, addresses.first ]
    rescue URI::InvalidURIError
      Result.failure("invalid URL")
    end

    def fetch(uri, ip)
      raise DeadlineExceeded if now > @deadline

      http = Net::HTTP.new(uri.hostname, uri.port)
      http.ipaddr = ip # connect to the vetted address; Host header and SNI keep the name
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = http.read_timeout = http.write_timeout = @timeout

      request = Net::HTTP::Get.new(uri.request_uri)
      request["User-Agent"] = USER_AGENT
      request["Accept"] = "text/html,application/xhtml+xml;q=0.9,*/*;q=0.5"
      request["Accept-Encoding"] = "identity"

      http.start do |conn|
        conn.request(request) do |response|
          return [ :redirect, response["location"] ] if response.is_a?(Net::HTTPRedirection) && response["location"]
          return [ :error, "HTTP #{response.code}" ] unless response.is_a?(Net::HTTPSuccess)

          @charset = response.type_params["charset"]
          declared = response["content-length"]&.to_i
          raise TooLarge if declared && declared > @max_bytes

          return [ :ok, read_capped(response) ]
        end
      end
    end

    def read_capped(response)
      body = +""
      response.read_body do |chunk|
        body << chunk
        raise TooLarge if body.bytesize > @max_bytes
        raise DeadlineExceeded if now > @deadline
      end
      body
    end
  end
end
