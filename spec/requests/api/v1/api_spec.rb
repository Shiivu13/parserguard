require "rails_helper"

RSpec.describe "API v1", type: :request do
  let!(:token) { ApiKey.generate!(name: "spec").last }
  let(:headers) { { "X-Api-Key" => token } }
  def json = response.parsed_body

  def api_get(path, **params) = get(path, params:, headers:)
  def api_post(path, body = {}) = post(path, params: body, headers:, as: :json)

  describe "authentication" do
    it "rejects missing and wrong keys with the error schema" do
      get "/api/v1/snapshots"
      expect(response).to have_http_status(:unauthorized)
      expect(json).to eq("error" => { "code" => "unauthorized", "message" => "missing or invalid X-Api-Key" })

      get "/api/v1/snapshots", headers: { "X-Api-Key" => "pg_wrong" }
      expect(response).to have_http_status(:unauthorized)
    end

    it "rejects revoked keys" do
      ApiKey.first.revoke!
      api_get "/api/v1/snapshots"
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "snapshots" do
    it "creates from raw html, then dedupes" do
      api_post "/api/v1/snapshots", { engine: "google", html: serp_fixture("baseline"), query: "ruby" }
      expect(response).to have_http_status(:created)
      expect(json["data"]).to include("engine" => "google", "version" => 1, "baseline" => true, "source" => "api")
      expect(json["data"]).not_to have_key("html")

      api_post "/api/v1/snapshots", { engine: "google", html: serp_fixture("baseline") }
      expect(response).to have_http_status(:ok)
      expect(json["meta"]).to eq("duplicate" => true)
    end

    it "creates from a URL and maps fetch failures to 502" do
      allow(Ingestion::UrlFetcher).to receive(:call).with("https://example.com/s")
        .and_return(Result.success("<html><body>x</body></html>", final_url: "https://example.com/s"))
      api_post "/api/v1/snapshots", { engine: "google", url: "https://example.com/s" }
      expect(response).to have_http_status(:created)
      expect(json["data"]).to include("source" => "url", "source_ref" => "https://example.com/s")

      allow(Ingestion::UrlFetcher).to receive(:call).and_return(Result.failure("host resolves to a private address"))
      api_post "/api/v1/snapshots", { engine: "google", url: "http://127.0.0.1/" }
      expect(response).to have_http_status(:bad_gateway)
      expect(json.dig("error", "message")).to include("private")
    end

    it "validates input" do
      api_post "/api/v1/snapshots", { engine: "google" }
      expect(response).to have_http_status(:unprocessable_entity)

      api_post "/api/v1/snapshots", { html: "<p>x</p>" }
      expect(json.dig("error", "code")).to eq("invalid_params")
    end

    it "paginates, filters and only returns html when asked" do
      snaps = import_google_fixtures
      api_get "/api/v1/snapshots", per: 2, page: 2
      expect(json["meta"]).to eq("page" => 2, "per" => 2, "total" => 4)
      expect(json["data"].size).to eq(2)

      api_get "/api/v1/snapshots", baseline: "true"
      expect(json["data"].map { |s| s["id"] }).to eq([ snaps["baseline"].id.to_s ])

      api_get "/api/v1/snapshots/#{snaps['broken'].id}", include: "html"
      expect(json.dig("data", "html")).to include("Before you continue")
    end

    it "caps per-page size" do
      api_get "/api/v1/snapshots", per: 10_000
      expect(json.dig("meta", "per")).to eq(100)
    end

    it "returns 404 for unknown and malformed ids" do
      api_get "/api/v1/snapshots/#{BSON::ObjectId.new}"
      expect(response).to have_http_status(:not_found)
      api_get "/api/v1/snapshots/not-an-id"
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "contracts, runs and healing" do
    let!(:contract) { google_contract }
    let!(:snaps) { import_google_fixtures }

    it "lists and shows contracts" do
      api_get "/api/v1/contracts"
      expect(json["data"].first).to include("key" => "google/organic_results", "version" => 1)
      expect(json["data"].first["fields"].map { |f| f["name"] }).to include("title", "link")
    end

    it "creates a contract and rejects an invalid one" do
      api_post "/api/v1/contracts", {
        engine: "bing", result_type: "organic_results", container_selector: "li.b_algo",
        fields: [ { name: "title", selector: "h2", value_type: "string" } ]
      }
      expect(response).to have_http_status(:created)
      expect(json.dig("data", "fields", 0, "selector")).to eq("h2")

      api_post "/api/v1/contracts", { engine: "bing", result_type: "organic_results", container_selector: "x" }
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "bumps the version only when selectors change" do
      patch "/api/v1/contracts/#{contract.id}", params: { min_extraction_rate: 0.8 }, headers:, as: :json
      expect(json["data"]).to include("min_extraction_rate" => 0.8, "version" => 1)

      patch "/api/v1/contracts/#{contract.id}", params: { container_selector: "div.MjjYud" }, headers:, as: :json
      expect(json.dig("data", "version")).to eq(2)
    end

    it "runs a contract and lists runs" do
      api_post "/api/v1/contracts/#{contract.id}/runs", { snapshot_id: snaps["baseline"].id.to_s }
      expect(response).to have_http_status(:created)
      expect(json["data"]).to include("status" => "passed", "extraction_rate" => 1.0)
      expect(json.dig("data", "items").size).to eq(4)

      api_get "/api/v1/runs", contract_id: contract.id.to_s, status: "passed"
      expect(json["data"].size).to eq(1)
      expect(json["data"].first).not_to have_key("items")
    end

    it "heals, accepts and rejects suggestions" do
      api_post "/api/v1/contracts/#{contract.id}/heal", { field: "title", snapshot_id: snaps["class_rename"].id.to_s }
      expect(response).to have_http_status(:created)
      suggestion_id = json.dig("data", "id")
      expect(json.dig("data", "candidates", 0, "selector")).to eq("h3")

      api_post "/api/v1/suggestions/#{suggestion_id}/accept"
      expect(response).to have_http_status(:ok)
      expect(json.dig("contract", "fields").detect { |f| f["name"] == "title" }["selector"]).to eq("h3")
      expect(json.dig("contract", "revisions", 0)).to include("from" => "h3.LC20lb", "to" => "h3")

      api_post "/api/v1/suggestions/#{suggestion_id}/accept"
      expect(response).to have_http_status(:conflict)
      api_post "/api/v1/suggestions/#{suggestion_id}/reject"
      expect(response).to have_http_status(:conflict)
    end

    it "reports healing failures as 422" do
      api_post "/api/v1/contracts/#{contract.id}/heal", { field: "price", snapshot_id: snaps["class_rename"].id.to_s }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json.dig("error", "message")).to eq("unknown field price")
    end
  end

  describe "drift events" do
    let!(:event) { create(:drift_event, severity: "major") }

    it "filters by severity and acknowledges" do
      create(:drift_event, severity: "none")
      api_get "/api/v1/drift_events", severity: "major,broken"
      expect(json["data"].map { |e| e["id"] }).to eq([ event.id.to_s ])

      api_post "/api/v1/drift_events/#{event.id}/acknowledge"
      expect(json.dig("data", "acknowledged_at")).to be_present
    end
  end
end
