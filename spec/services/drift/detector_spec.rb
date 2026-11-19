require "rails_helper"

RSpec.describe Drift::Detector do
  let!(:contract) { google_contract }
  let!(:snaps) { import_google_fixtures }

  def detect(name) = described_class.call(snaps[name]).value

  it "refuses to compare the baseline with itself" do
    expect(described_class.call(snaps["baseline"]).error_message).to eq("snapshot is the baseline")
  end

  it "fails when the target has no baseline" do
    snaps["baseline"].set(baseline: false)
    expect(described_class.call(snaps["broken"])).to be_failure
  end

  it "marks renamed classes as major with the failing fields" do
    event = detect("class_rename")

    expect(event.severity).to eq("broken") .or eq("major")
    expect(event.broken_fields.map { |f| f["field"] }).to match_array(%w[title link snippet])
    expect(event.broken_fields.first["contract"]).to eq("google/organic_results")
    expect(event.removed_paths.map { |p| p["path"] }).to include(a_string_including("yuRUbf"))
  end

  it "flags a missing container on structural change" do
    event = detect("structural_change")
    expect(event.severity).to eq("broken")
    expect(event.broken_fields).to contain_exactly(include("field" => "_container"))
    expect(event.drift_score).to be >= 0.2
  end

  it "keeps layout-only drift at minor while every contract passes" do
    event = detect("ads_added")
    expect(event.drift_score).to be > 0.2
    expect(event.broken_fields).to eq([])
    expect(event.severity).to eq("minor")
  end

  it "marks the consent page as broken" do
    expect(detect("broken").severity).to eq("broken")
  end

  it "rates layout-only drift without contracts by score alone" do
    contract.update!(active: false)
    event = detect("class_rename")
    expect(event.broken_fields).to eq([])
    expect(event.severity).to eq(event.drift_score >= 0.2 ? "major" : "minor")
  end

  it "is idempotent per snapshot pair" do
    first = described_class.call(snaps["broken"])
    second = described_class.call(snaps["broken"])

    expect(first.meta[:created]).to be(true)
    expect(second.meta[:created]).to be(false)
    expect(second.value.id).to eq(first.value.id)
    expect(DriftEvent.count).to eq(1)
  end

  it "records one contract run per active contract" do
    expect { detect("class_rename") }.to change(ContractRun, :count).by(1)
  end
end
