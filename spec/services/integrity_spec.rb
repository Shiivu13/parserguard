require "rails_helper"

# Concurrency, idempotency and data-integrity edge cases across services.
RSpec.describe "Data integrity" do
  let!(:token) { ApiKey.generate!(name: "spec").last }
  let(:headers) { { "X-Api-Key" => token } }

  describe "contract updates" do
    let!(:contract) { google_contract }

    it "leaves fields and version untouched when an API update is invalid", type: :request do
      patch "/api/v1/contracts/#{contract.id}", headers:, as: :json,
                                                 params: { min_extraction_rate: 5, fields: [ { name: "title", selector: "h3" } ] }
      expect(response).to have_http_status(:unprocessable_entity)

      patch "/api/v1/contracts/#{contract.id}", headers:, as: :json,
                                                 params: { fields: [ { name: "title", selector: "h3" }, { name: "title", selector: "h2" } ] }
      expect(response).to have_http_status(:unprocessable_entity)

      contract.reload
      expect(contract.field_specs.map(&:name)).to eq(%w[title link snippet displayed_link])
      expect(contract.version).to eq(1)
      expect(contract).to be_valid
    end

    it "does not clobber a stored contract with an invalid forced YAML reload" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "bad.yml"), { "engine" => "google", "result_type" => "organic_results",
                                                "container_selector" => "div *", "fields" => [ { "name" => "t", "selector" => "h3" } ] }.to_yaml)
        result = Contracts::Loader.call(dir:, force: true).first
        expect(result).to be_failure
      end
      expect(contract.reload.container_selector).to eq("div.g")
    end

    it "gives each of two accepts from stale copies its own version" do
      snaps = import_google_fixtures
      title = Healing::Healer.call(contract:, field_name: "title", snapshot: snaps["class_rename"]).value
      snippet = Healing::Healer.call(contract:, field_name: "snippet", snapshot: snaps["class_rename"]).value
      stale_title = SelectorSuggestion.find(title.id)
      stale_snippet = SelectorSuggestion.find(snippet.id)

      expect(Healing::SuggestionAcceptor.call(stale_title)).to be_ok
      expect(Healing::SuggestionAcceptor.call(stale_snippet)).to be_ok

      contract.reload
      expect(contract.version).to eq(3)
      expect(contract.revisions.map(&:version)).to eq([ 2, 3 ])
      expect(contract.field_spec("title").selector).to eq("h3")
      expect(contract.field_spec("snippet").selector).to eq("div.lEBKkf")
    end

    it "retries the compare-and-set when the contract changed underneath" do
      calls = 0
      ParserContract.change!(contract.id) do |doc|
        calls += 1
        ParserContract.where(_id: contract.id).update_all("$inc" => { version: 1 }) if calls == 1
        doc["min_extraction_rate"] = 0.8
        { bump: false }
      end
      expect(calls).to eq(2)
      expect(contract.reload).to have_attributes(min_extraction_rate: 0.8, version: 2)
    end

    it "requires at least one required field and scores optional-only extraction as complete" do
      expect(build(:parser_contract, field_specs: [ build(:field_spec, required: false) ])).not_to be_valid

      optional_only = build(:parser_contract, field_specs: [ build(:field_spec, required: false) ])
      evaluation = Contracts::Runner.evaluate(optional_only, serp_doc("baseline"))
      expect(evaluation.extraction_rate).to eq(1.0)
    end
  end

  describe "suggestion state races" do
    let(:suggestion) { create(:selector_suggestion, candidates: [ { "selector" => "h3.x" } ]) }

    it "does not let a reject overwrite an accept" do
      stale = SelectorSuggestion.find(suggestion.id)
      Healing::SuggestionAcceptor.call(suggestion)

      expect(stale.reject!).to be(false)
      expect(suggestion.reload.status).to eq("accepted")
    end

    it "reclaims a claim abandoned by a crashed accept" do
      suggestion.set(status: "accepting", claimed_at: 10.minutes.ago)
      expect(SelectorSuggestion.pending.to_a).to include(suggestion)
      expect(Healing::SuggestionAcceptor.call(suggestion.reload)).to be_ok
    end

    it "keeps a fresh claim exclusive" do
      suggestion.set(status: "accepting", claimed_at: Time.current)
      expect(suggestion.reload).not_to be_pending
      expect(suggestion.claim!).to be(false)
    end

    it "allows only one pending suggestion per field and snapshot" do
      snapshot = create(:snapshot)
      create(:selector_suggestion, contract: suggestion.contract, field_name: "title", snapshot:)
      expect {
        create(:selector_suggestion, contract: suggestion.contract, field_name: "title", snapshot:)
      }.to raise_error(Mongo::Error::OperationFailure)
    end
  end

  describe DetectDriftJob do
    it "still queues healing and the alert when retried after the event exists" do
      google_contract
      snaps = import_google_fixtures
      Drift::Detector.call(snaps["class_rename"]) # first attempt died after creating the event

      described_class.perform_now(snaps["class_rename"].id.to_s)
      fields = enqueued_jobs.select { |j| j["job_class"] == "HealFieldJob" }.map { |j| j["arguments"][1] }
      expect(fields).to match_array(%w[title link snippet])
      expect(SendAlertJob).to have_been_enqueued
    end
  end

  describe "snapshots" do
    it "dedupes per target, so the same bytes can seed another device" do
      html = serp_fixture("baseline")
      desktop = Ingestion::SnapshotCreator.call(html:, engine: "google", source: "api").value
      mobile = Ingestion::SnapshotCreator.call(html:, engine: "google", source: "api", device: "mobile")

      expect(mobile.meta[:duplicate]).to be(false)
      expect(mobile.value.id).not_to eq(desktop.id)
      expect(mobile.value.baseline).to be(true)
    end

    it "returns a full document for duplicates" do
      Ingestion::SnapshotCreator.call(html: serp_fixture("broken"), engine: "google", source: "api")
      dup = Ingestion::SnapshotCreator.call(html: serp_fixture("broken"), engine: "google", source: "api")
      expect(dup.value.html).to include("Before you continue")
    end

    it "never stores two baselines for one target" do
      a = create(:snapshot, baseline: true)
      expect { create(:snapshot, baseline: true) }.to raise_error(Mongo::Error::OperationFailure)
      b = create(:snapshot)
      b.promote_to_baseline!
      expect(a.reload.baseline).to be(false)
    end

    it "decodes Latin-1 pages instead of dropping characters", type: :request do
      latin1 = "<html><head><meta charset=\"iso-8859-1\"></head><body><div id=\"rso\"><h3>Caf\xE9 cr\xE8me</h3></div></body></html>".b
      snap = Ingestion::SnapshotCreator.call(html: latin1, engine: "google", source: "api").value

      expect(snap.html).to include("Café crème")
      get "/api/v1/snapshots/#{snap.id}", params: { include: "html" }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("data", "html")).to include("Café crème")
    end

    it "uses the HTTP charset when the page does not declare one" do
      expect(Html::Encoding.to_utf8("na\xEFve".b, charset: "windows-1252")).to eq("naïve")
      expect(Html::Encoding.to_utf8("plain ascii")).to eq("plain ascii")
    end
  end

  describe Contracts::TypeValidator do
    {
      [ "About 1,230 results (0.45 seconds)", "integer" ] => [ true, 1230 ],
      [ "4.5 stars", "integer" ] => [ false, nil ],
      [ "-12", "integer" ] => [ true, -12 ],
      [ "https://example.com/url?q=foo", "url" ] => [ true, "https://example.com/url?q=foo" ],
      [ "https://www.google.com/url?q=https://a.com/", "url" ] => [ true, "https://a.com/" ]
    }.each do |(value, type), expected|
      it "#{type}: #{value.inspect}" do
        expect(described_class.call(value, type)).to eq(expected)
      end
    end
  end

  describe ScheduledIngestJob do
    around do |ex|
      original = Rails.application.config.parserguard
      Rails.application.config.parserguard = original.merge(watch: [ { url: "https://a.test/" }, { engine: "google", url: "https://b.test/" } ])
      ex.run
    ensure
      Rails.application.config.parserguard = original
    end

    it "keeps going when one target is misconfigured" do
      allow(Ingestion::UrlFetcher).to receive(:call).and_return(Result.success(serp_fixture("baseline")))
      described_class.perform_now
      expect(Snapshot.count).to eq(1)
    end
  end

  describe Healing::TextMatcher do
    it "locates url fields stored in attributes other than href" do
      doc = Nokogiri::HTML5("<div><img src='https://cdn.test/a.png'></div>")
      expect(described_class.find([ doc.root ], "https://cdn.test/a.png", url: true, attr: "src").name).to eq("img")
    end
  end
end
