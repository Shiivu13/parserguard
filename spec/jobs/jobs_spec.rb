require "rails_helper"

RSpec.describe DetectDriftJob do
  let!(:contract) { google_contract }
  let!(:snaps) { import_google_fixtures }

  it "creates a drift event, enqueues healing per broken field and an alert" do
    expect { described_class.perform_now(snaps["class_rename"].id.to_s) }.to change(DriftEvent, :count).by(1)

    heal_args = enqueued_jobs.select { |j| j["job_class"] == "HealFieldJob" }.map { |j| j["arguments"][1] }
    expect(heal_args).to match_array(%w[title link snippet])
    expect(SendAlertJob).to have_been_enqueued.once
  end

  it "does nothing twice for the same snapshot" do
    described_class.perform_now(snaps["broken"].id.to_s)
    clear_enqueued_jobs
    described_class.perform_now(snaps["broken"].id.to_s)
    expect(enqueued_jobs).to be_empty
  end

  it "skips baselines and missing snapshots" do
    described_class.perform_now(snaps["baseline"].id.to_s)
    described_class.perform_now(BSON::ObjectId.new.to_s)
    expect(DriftEvent.count).to eq(0)
  end
end

RSpec.describe HealFieldJob do
  it "creates a suggestion" do
    contract = google_contract
    snaps = import_google_fixtures
    described_class.perform_now(contract.id.to_s, "title", snaps["class_rename"].id.to_s)
    expect(SelectorSuggestion.first.top_candidate["selector"]).to eq("h3")
  end
end

RSpec.describe RunContractsJob do
  let!(:contract) { google_contract }
  let!(:snaps) { import_google_fixtures }

  it "chains healing to fields still failing after a container fix" do
    contract.update!(container_selector: "div.MjjYud")
    described_class.perform_now(contract.id.to_s, snaps["structural_change"].id.to_s)

    expect(ContractRun.last.extraction_rate).to be_within(0.001).of(0.6667)
    expect(HealFieldJob).to have_been_enqueued.with(contract.id.to_s, "link", snaps["structural_change"].id.to_s)
  end

  it "does not re-heal a field that already has a pending suggestion" do
    create(:selector_suggestion, contract:, field_name: "title")
    described_class.perform_now(contract.id.to_s, snaps["class_rename"].id.to_s)
    heal_fields = enqueued_jobs.select { |j| j["job_class"] == "HealFieldJob" }.map { |j| j["arguments"][1] }
    expect(heal_fields).to match_array(%w[link snippet])
  end

  it "stops when the contract passes" do
    described_class.perform_now(contract.id.to_s, snaps["baseline"].id.to_s)
    expect(enqueued_jobs).to be_empty
  end
end

RSpec.describe SendAlertJob do
  let(:event) { create(:drift_event, severity: "major", broken_fields: [ { "contract" => "google/organic_results", "field" => "title", "rate" => 0.0 } ]) }
  let(:hook) { "https://hooks.slack.test/services/T/B/x" }

  around do |ex|
    original = Rails.application.config.parserguard
    Rails.application.config.parserguard = original.deep_merge(alerts: { webhook_url: hook })
    ex.run
  ensure
    Rails.application.config.parserguard = original
  end

  it "posts a Slack payload once" do
    stub = stub_request(:post, hook).with { |req| JSON.parse(req.body)["text"].include?("MAJOR") }.to_return(status: 200)
    described_class.perform_now(event.id.to_s)
    described_class.perform_now(event.id.to_s)

    expect(stub).to have_been_requested.once
    expect(event.reload.alerted_at).to be_present
  end

  it "retries on 5xx without marking the event alerted" do
    stub_request(:post, hook).to_return(status: 503)
    described_class.perform_now(event.id.to_s)

    expect(event.reload.alerted_at).to be_nil
    expect(described_class).to have_been_enqueued.with(event.id.to_s)
  end

  it "does not retry on 4xx" do
    stub_request(:post, hook).to_return(status: 404)
    described_class.perform_now(event.id.to_s)
    expect(described_class).not_to have_been_enqueued
  end
end

RSpec.describe ScheduledIngestJob do
  around do |ex|
    original = Rails.application.config.parserguard
    Rails.application.config.parserguard = original.merge(watch: [ { engine: "google", url: "https://mirror.test/q.html" } ])
    ex.run
  ensure
    Rails.application.config.parserguard = original
  end

  it "ingests watched URLs and enqueues detection for new non-baseline snapshots" do
    allow(Ingestion::UrlFetcher).to receive(:call).and_return(
      Result.success(serp_fixture("baseline"), final_url: "https://mirror.test/q.html"),
      Result.success(serp_fixture("class_rename"), final_url: "https://mirror.test/q.html")
    )
    described_class.perform_now
    described_class.perform_now

    expect(Snapshot.count).to eq(2)
    expect(DetectDriftJob).to have_been_enqueued.twice
  end
end

RSpec.describe Alerts::SlackPayload do
  it "summarizes severity, score, broken fields and a link" do
    event = build(:drift_event, severity: "broken", drift_score: 0.9559,
                                broken_fields: [ { "contract" => "google/organic_results", "field" => "_container", "rate" => 0 } ])
    payload = described_class.call(event, app_url: "https://pg.example.com/")

    text = payload[:blocks].first.dig(:text, :text)
    expect(text).to include("*BROKEN*", "0.956", "`google/organic_results#_container`", "https://pg.example.com/drift_events/#{event.id}")
    expect(payload[:text]).not_to include("*")
    expect(payload[:parserguard][:severity]).to eq("broken")
  end
end

RSpec.describe "API job hooks", type: :request do
  let!(:token) { ApiKey.generate!(name: "spec").last }

  it "enqueues drift detection for new non-baseline snapshots only" do
    post "/api/v1/snapshots", params: { engine: "google", html: serp_fixture("baseline") }, headers: { "X-Api-Key" => token }, as: :json
    post "/api/v1/snapshots", params: { engine: "google", html: serp_fixture("broken") }, headers: { "X-Api-Key" => token }, as: :json
    expect(DetectDriftJob).to have_been_enqueued.once
  end
end
