require "rails_helper"

RSpec.describe "Dashboard", type: :request do
  let!(:contract) { google_contract }
  let!(:snaps) { import_google_fixtures }
  let!(:event) { Drift::Detector.call(snaps["class_rename"]).value }
  let!(:suggestion) { Healing::Healer.call(contract:, field_name: "title", snapshot: snaps["class_rename"], drift_event: event).value }

  it "renders every page" do
    [
      root_path, drift_events_path, drift_event_path(event), suggestions_path, suggestions_path(status: "accepted"),
      suggestion_path(suggestion), contracts_path, contract_path(contract), snapshots_path, snapshot_path(snaps["broken"])
    ].each do |path|
      get path
      expect(response).to have_http_status(:ok), "#{path} returned #{response.status}"
    end
  end

  it "shows engine health and the drift timeline" do
    get root_path
    expect(response.body).to include("google · en-US · desktop", "google/organic_results", "badge-broken")

    get drift_events_path
    expect(response.body).to include('data-controller="timeline-filter"', 'data-severity="broken"')
  end

  it "shows before/after values side by side" do
    get suggestion_path(suggestion)
    expect(response.body).to include("h3.LC20lb", "Ruby Programming Language", 'data-accept-suggestion-selector-param="h3"')
  end

  it "accepts a candidate over JSON and queues a re-run" do
    post accept_suggestion_path(suggestion, format: :json), params: { selector: "h3" }, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("status" => "accepted", "selector" => "h3", "contract_version" => 2)
    expect(RunContractsJob).to have_been_enqueued.with(contract.id.to_s, snaps["class_rename"].id.to_s)
  end

  it "returns 422 JSON for an invalid selector and falls back to HTML redirects" do
    post accept_suggestion_path(suggestion, format: :json), params: { selector: "h3[[" }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)

    post accept_suggestion_path(suggestion)
    expect(response).to redirect_to(suggestion_path(suggestion))
    expect(suggestion.reload.status).to eq("accepted")
  end

  it "rejects, acknowledges, promotes and re-runs" do
    other = Healing::Healer.call(contract:, field_name: "link", snapshot: snaps["class_rename"]).value
    post reject_suggestion_path(other)
    expect(other.reload.status).to eq("rejected")

    post acknowledge_drift_event_path(event)
    expect(event.reload.acknowledged_at).to be_present

    post promote_snapshot_path(snaps["class_rename"])
    expect(Snapshot.baseline_for("google", "en-US", "desktop")).to eq(snaps["class_rename"])

    expect { post run_contract_path(contract, snapshot_id: snaps["baseline"].id) }.to change(ContractRun, :count).by(1)
  end

  it "escapes captured HTML in the source preview" do
    get snapshot_path(snaps["broken"])
    expect(response.body).to include("&lt;form action=&quot;/save&quot;")
    expect(response.body).not_to include('<form action="/save"')
  end

  it "404s unknown ids" do
    get suggestion_path("nope")
    expect(response).to have_http_status(:not_found)
    get drift_event_path(BSON::ObjectId.new)
    expect(response).to have_http_status(:not_found)
  end

  context "with DASHBOARD_PASSWORD set" do
    around do |ex|
      ENV["DASHBOARD_PASSWORD"] = "s3cret"
      ex.run
    ensure
      ENV.delete("DASHBOARD_PASSWORD")
    end

    it "requires basic auth" do
      get root_path
      expect(response).to have_http_status(:unauthorized)

      get root_path, headers: { "Authorization" => ActionController::HttpAuthentication::Basic.encode_credentials("admin", "s3cret") }
      expect(response).to have_http_status(:ok)
    end
  end
end
