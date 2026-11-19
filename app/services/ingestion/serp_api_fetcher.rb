module Ingestion
  # Gets real SERP HTML without scraping the engine directly: runs a SerpApi
  # search, then downloads the page SerpApi captured (search_metadata.raw_html_file).
  class SerpApiFetcher
    ENDPOINT = "https://serpapi.com/search.json".freeze

    def self.call(**) = new(**).call

    def initialize(query:, engine: "google", location: nil, api_key: ENV["SERPAPI_KEY"], connection: nil)
      @query = query
      @engine = engine
      @location = location
      @api_key = api_key
      @connection = connection || Faraday.new { |f| f.options.timeout = 30 }
    end

    def call
      return Result.failure("SERPAPI_KEY is not set") if @api_key.blank?

      search = @connection.get(ENDPOINT, search_params)
      return Result.failure("SerpApi search HTTP #{search.status}") unless search.success?

      metadata = JSON.parse(search.body).fetch("search_metadata", {})
      html_url = metadata["raw_html_file"]
      return Result.failure("SerpApi response has no raw_html_file") if html_url.blank?

      page = @connection.get(html_url)
      return Result.failure("raw_html_file HTTP #{page.status}") unless page.success?

      Result.success(page.body.to_s, source_ref: metadata["id"], raw_html_file: html_url)
    rescue JSON::ParserError
      Result.failure("SerpApi returned invalid JSON")
    rescue Faraday::Error => e
      Result.failure("SerpApi request failed: #{e.class.name.demodulize}")
    end

    private

    def search_params
      { engine: @engine, q: @query, location: @location, api_key: @api_key }.compact
    end
  end
end
