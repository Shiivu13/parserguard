require "rails_helper"

RSpec.describe Ingestion::UrlFetcher do
  let(:public_dns) { ->(_host) { [ "93.184.216.34" ] } }
  subject(:fetcher) { described_class.new(resolver: public_dns) }

  it "returns the body on 200" do
    stub_request(:get, "https://example.com/serp").to_return(status: 200, body: "<html>ok</html>")
    result = fetcher.call("https://example.com/serp")
    expect(result).to be_ok
    expect(result.value).to eq("<html>ok</html>")
  end

  it "fails on non-2xx" do
    stub_request(:get, "https://example.com/missing").to_return(status: 404)
    expect(fetcher.call("https://example.com/missing").error_message).to eq("HTTP 404")
  end

  it "fails on timeout" do
    stub_request(:get, "https://example.com/slow").to_timeout
    expect(fetcher.call("https://example.com/slow").error_message).to eq("timeout")
  end

  it "fails when the body is larger than the cap" do
    stub_request(:get, "https://example.com/big").to_return(body: "x" * 6_000_000)
    expect(fetcher.call("https://example.com/big").error_message).to include("exceeds")
  end

  it "rejects non-http schemes" do
    expect(fetcher.call("file:///etc/passwd").error_message).to include("http/https")
  end

  [ "127.0.0.1", "10.1.2.3", "169.254.169.254", "192.168.1.5", "::1" ].each do |ip|
    it "blocks hosts that resolve to #{ip}" do
      blocked = described_class.new(resolver: ->(_h) { [ ip ] })
      expect(blocked.call("http://internal.test/").error_message).to include("private")
      expect(a_request(:any, /internal/)).not_to have_been_made
    end
  end

  it "re-checks redirects against the private-IP guard" do
    resolver = ->(host) { host == "evil.test" ? [ "127.0.0.1" ] : [ "93.184.216.34" ] }
    stub_request(:get, "https://example.com/r").to_return(status: 302, headers: { "Location" => "http://evil.test/admin" })

    result = described_class.new(resolver:).call("https://example.com/r")
    expect(result.error_message).to include("private")
  end

  it "follows safe redirects" do
    stub_request(:get, "https://example.com/a").to_return(status: 301, headers: { "Location" => "/b" })
    stub_request(:get, "https://example.com/b").to_return(body: "final")
    result = fetcher.call("https://example.com/a")
    expect(result.value).to eq("final")
    expect(result.meta[:final_url]).to eq("https://example.com/b")
  end
end

RSpec.describe Ingestion::SerpApiFetcher do
  let(:search_url) { %r{\Ahttps://serpapi\.com/search\.json\?} }

  it "fails fast without an API key" do
    expect(described_class.call(query: "ruby", api_key: nil).error_message).to eq("SERPAPI_KEY is not set")
  end

  it "downloads raw_html_file from search metadata" do
    stub_request(:get, search_url)
      .with(query: hash_including("q" => "ruby", "engine" => "google", "api_key" => "k"))
      .to_return(body: { search_metadata: { id: "abc", raw_html_file: "https://serpapi.com/searches/abc.html" } }.to_json)
    stub_request(:get, "https://serpapi.com/searches/abc.html").to_return(body: "<html>serp</html>")

    result = described_class.call(query: "ruby", api_key: "k")
    expect(result.value).to eq("<html>serp</html>")
    expect(result.meta[:source_ref]).to eq("abc")
  end

  it "reports missing raw_html_file and bad JSON" do
    stub_request(:get, search_url).to_return(body: { search_metadata: {} }.to_json)
    expect(described_class.call(query: "q", api_key: "k").error_message).to include("raw_html_file")

    WebMock.reset!
    stub_request(:get, search_url).to_return(body: "nope")
    expect(described_class.call(query: "q", api_key: "k").error_message).to include("invalid JSON")
  end

  it "reports HTTP errors without leaking the key" do
    stub_request(:get, search_url).to_return(status: 401)
    result = described_class.call(query: "q", api_key: "secret-key")
    expect(result.error_message).to eq("SerpApi search HTTP 401")
    expect(result.error_message).not_to include("secret-key")
  end
end
