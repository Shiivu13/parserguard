require "rails_helper"

RSpec.describe Ingestion::SnapshotCreator do
  let(:args) { { engine: "google", source: "fixture", query: "q" } }

  it "creates version 1 as the baseline with histograms" do
    result = described_class.call(html: serp_fixture("baseline"), **args)

    expect(result).to be_ok
    snap = result.value
    expect(snap.version).to eq(1)
    expect(snap.baseline).to be(true)
    expect(snap.tag_histogram).not_to be_empty
    expect(snap.class_histogram.map(&:first)).to include(a_string_matching(/div\.g\.tF2Cxc/))
    expect(result.meta[:duplicate]).to be(false)
  end

  it "increments the version and keeps the first baseline" do
    described_class.call(html: serp_fixture("baseline"), **args)
    second = described_class.call(html: serp_fixture("class_rename"), **args).value

    expect(second.version).to eq(2)
    expect(second.baseline).to be(false)
  end

  it "dedupes identical HTML" do
    first = described_class.call(html: serp_fixture("baseline"), **args).value
    again = described_class.call(html: serp_fixture("baseline"), **args)

    expect(again).to be_ok
    expect(again.meta[:duplicate]).to be(true)
    expect(again.value.id).to eq(first.id)
    expect(Snapshot.count).to eq(1)
  end

  it "versions targets independently" do
    described_class.call(html: serp_fixture("baseline"), **args)
    mobile = described_class.call(html: serp_fixture("broken"), device: "mobile", **args).value
    expect(mobile.version).to eq(1)
    expect(mobile.baseline).to be(true)
  end

  it "rejects empty and oversized HTML" do
    expect(described_class.call(html: "  ", **args).errors).to eq([ "html is empty" ])

    allow(Rails.application.config).to receive(:parserguard)
      .and_return(Rails.application.config.parserguard.deep_merge(ingestion: { max_bytes: 10 }))
    expect(described_class.call(html: "<p>too long</p>", **args).error_message).to include("exceeds")
  end

  it "returns validation errors for bad attributes" do
    result = described_class.call(html: "<p>x</p>", engine: "Bad Engine", source: "fixture")
    expect(result).to be_failure
    expect(result.error_message).to include("Engine")
  end
end

RSpec.describe Ingestion::FixtureImporter do
  it "imports fixtures in manifest order, first one as baseline" do
    results = described_class.call(dir: Rails.root.join("spec/fixtures/serp/google"))

    expect(results).to all(be_ok)
    snaps = results.map(&:value)
    expect(snaps.map(&:source_ref)).to eq(%w[baseline.html ads_added.html class_rename.html structural_change.html broken.html])
    expect(snaps.map(&:version)).to eq([ 1, 2, 3, 4, 5 ])
    expect(Snapshot.baseline_for("google", "en-US", "desktop").source_ref).to eq("baseline.html")
  end

  it "is idempotent" do
    dir = Rails.root.join("spec/fixtures/serp/google")
    described_class.call(dir:)
    described_class.call(dir:)
    expect(Snapshot.count).to eq(5)
  end
end
