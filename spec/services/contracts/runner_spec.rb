require "rails_helper"

RSpec.describe Contracts::Runner do
  let(:contract) { google_contract }
  let(:snapshots) { import_google_fixtures }

  it "extracts every organic result from the baseline" do
    run = described_class.call(contract, snapshots["baseline"])

    expect(run).to be_passed
    expect(run.container_count).to eq(4)
    expect(run.extraction_rate).to eq(1.0)
    expect(run.items.first).to include(
      "title" => "Ruby Programming Language",
      "link" => "https://www.ruby-lang.org/en/",
      "displayed_link" => "https://www.ruby-lang.org"
    )
    expect(run.field_rate("snippet")).to eq(1.0)
    expect(run.contract_version).to eq(contract.version)
    expect(run.duration_ms).to be >= 0
  end

  it "fails every required field when classes are renamed" do
    run = described_class.call(contract, snapshots["class_rename"])

    expect(run).not_to be_passed
    expect(run.container_count).to eq(4)
    expect(run.extraction_rate).to eq(0.0)
    expect(run.failing_fields(0.9)).to match_array(%w[title link snippet])
    expect(run.validation_errors.first).to include("field" => "title", "message" => "missing")
  end

  it "finds no containers after a structural change" do
    run = described_class.call(contract, snapshots["structural_change"])
    expect(run.container_count).to eq(0)
    expect(run.extraction_rate).to eq(0.0)
  end

  it "handles a page without results" do
    run = described_class.call(contract, snapshots["broken"])
    expect(run.container_count).to eq(0)
    expect(run.status).to eq("failed")
  end

  it "computes partial rates per required cell" do
    doc = Nokogiri::HTML5(<<~HTML)
      <div id="rso">
        <div class="g"><div class="yuRUbf"><a href="https://a.com"><h3 class="LC20lb">A</h3></a></div><div class="VwiC3b">s</div></div>
        <div class="g"><div class="yuRUbf"><a href="javascript:x"><h3 class="LC20lb">B</h3></a></div></div>
      </div>
    HTML
    evaluation = described_class.evaluate(contract, doc)

    # 6 required cells, 4 valid (2nd item: bad link, missing snippet)
    expect(evaluation.extraction_rate).to eq(0.6667)
    expect(evaluation.validation_errors.map { |e| e["message"] }).to include("invalid url", "missing")
  end

  it "does not persist on evaluate" do
    described_class.evaluate(contract, serp_doc("baseline"))
    expect(ContractRun.count).to eq(0)
  end
end

RSpec.describe Contracts::Loader do
  it "creates contracts from YAML and skips existing ones" do
    first = described_class.call
    expect(first.map { |r| r.meta[:action] }).to eq([ :created ])

    contract = ParserContract.first
    contract.field_spec("title").selector = "h3.healed"
    contract.save!

    expect(described_class.call.map { |r| r.meta[:action] }).to eq([ :skipped ])
    expect(contract.reload.field_spec("title").selector).to eq("h3.healed")
  end

  it "replaces and bumps the version with force" do
    described_class.call
    result = described_class.call(force: true).first
    expect(result.meta[:action]).to eq(:replaced)
    expect(result.value.version).to eq(2)
  end
end
