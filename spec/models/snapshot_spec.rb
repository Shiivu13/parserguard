require "rails_helper"

RSpec.describe Snapshot do
  it "round-trips HTML through gzip and records size + digest" do
    html = "<html><body>héllo</body></html>"
    snap = create(:snapshot, html:)

    reloaded = described_class.find(snap.id)
    expect(reloaded.html).to eq(html)
    expect(reloaded.byte_size).to eq(html.bytesize)
    expect(reloaded.sha256).to eq(Digest::SHA256.hexdigest(html.b))
  end

  it "rejects unknown devices and sources" do
    expect(build(:snapshot, device: "tablet")).not_to be_valid
    expect(build(:snapshot, source: "ftp")).not_to be_valid
  end

  it "rejects engines with odd characters" do
    expect(build(:snapshot, engine: "Google.com")).not_to be_valid
  end

  it "enforces unique sha256" do
    create(:snapshot, html: "<p>same</p>")
    expect { create(:snapshot, html: "<p>same</p>") }.to raise_error(Mongo::Error::OperationFailure)
  end

  it "computes the next version per target" do
    create(:snapshot, version: 1)
    create(:snapshot, version: 4)
    create(:snapshot, version: 9, device: "mobile")
    expect(described_class.next_version("google", "en-US", "desktop")).to eq(5)
    expect(described_class.next_version("bing", "en-US", "desktop")).to eq(1)
  end

  it "keeps exactly one baseline per target" do
    a = create(:snapshot)
    b = create(:snapshot)
    a.promote_to_baseline!
    b.promote_to_baseline!
    expect(a.reload.baseline).to be(false)
    expect(described_class.baseline_for("google", "en-US", "desktop")).to eq(b)
  end

  it "excludes the HTML blob from light queries" do
    create(:snapshot)
    expect(described_class.light.first.attributes).not_to have_key("html_gz")
  end
end
