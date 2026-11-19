module Ingestion
  # Gets real SERP HTML without scraping the engine directly: runs a SerpApi
  # search, then downloads the page SerpApi captured (search_metadata.raw_html_file).
  class SerpApiFetcher
    ENDPOINT = "https://serpapi.com/search.json".freeze

    def self.call(**) = new(**).call

    RAW_HTML_HOST = /\A(?:[a-z0-9-]+\.)*serpapi\.com\z/

    def initialize(query:, engine: "google", location: nil, api_key: ENV["SERPAPI_KEY"], connection: nil, html_fetcher: nil)
      @query = query
      @engine = engine
      @location = location
      @api_key = api_key
      @connection = connection || Faraday.new { |f| f.options.timeout = 30 }
      # The captured page goes through the same SSRF/size guards as any URL.
      @html_fetcher = html_fetcher || UrlFetcher.new
    end

    def call
      return Result.failure("SERPAPI_KEY is not set") if @api_key.blank?

      search = @connection.get(ENDPOINT, search_params)
      return Result.failure("SerpApi search HTTP #{search.status}") unless search.success?

      metadata = JSON.parse(search.body).fetch("search_metadata", {})
      html_url = metadata["raw_html_file"]
      return Result.failure("SerpApi response has no raw_html_file") if html_url.blank?

      return Result.failure("raw_html_file is not an https serpapi.com URL") unless trusted_html_url?(html_url)

      page = @html_fetcher.call(html_url)
      return Result.failure("raw_html_file: #{page.error_message}") if page.failure?

      Result.success(page.value, source_ref: metadata["id"], raw_html_file: html_url)
    rescue JSON::ParserError
      Result.failure("SerpApi returned invalid JSON")
    rescue Faraday::Error => e
      Result.failure("SerpApi request failed: #{e.class.name.demodulize}")
    end

    private

    def trusted_html_url?(url)
      uri = URI.parse(url)
      uri.scheme == "https" && RAW_HTML_HOST.match?(uri.hostname.to_s.downcase)
    rescue URI::InvalidURIError
      false
    end

    def search_params
      { engine: @engine, q: @query, location: @location, api_key: @api_key }.compact
    end
  end
end
