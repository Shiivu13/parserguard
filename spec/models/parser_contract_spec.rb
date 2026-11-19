require "rails_helper"

RSpec.describe ParserContract do
  it "is valid with embedded fields" do
    expect(build(:parser_contract)).to be_valid
  end

  it "rejects duplicate field names" do
    contract = build(:parser_contract)
    contract.fields << build(:field_spec, name: "title")
    expect(contract).not_to be_valid
    expect(contract.errors[:fields].join).to include("title")
  end

  it "is unique per engine + result_type" do
    create(:parser_contract, result_type: "organic_results")
    expect(build(:parser_contract, result_type: "organic_results")).not_to be_valid
  end

  it "validates embedded field value types" do
    contract = build(:parser_contract)
    contract.fields.first.value_type = "date"
    expect(contract).not_to be_valid
  end

  it "resolves selectors including the container pseudo-field" do
    contract = build(:parser_contract)
    expect(contract.selector_for("link")).to eq("a[href]")
    expect(contract.selector_for("_container")).to eq("#rso div.g")
    expect(contract.required_fields.map(&:name)).to eq(%w[title link])
  end
end

RSpec.describe ContractRun do
  it "reports failing required fields only" do
    run = build(:contract_run, field_stats: [
      { "name" => "title", "required" => true, "rate" => 0.2 },
      { "name" => "link", "required" => true, "rate" => 1.0 },
      { "name" => "snippet", "required" => false, "rate" => 0.0 }
    ])
    expect(run.failing_fields(0.9)).to eq([ "title" ])
    expect(run.field_rate("link")).to eq(1.0)
    expect(run.field_rate("missing")).to eq(0.0)
  end
end

RSpec.describe DriftEvent do
  it "validates severity and score bounds" do
    expect(build(:drift_event, severity: "meh")).not_to be_valid
    expect(build(:drift_event, drift_score: 1.5)).not_to be_valid
  end

  it "flags major and broken as actionable" do
    expect(build(:drift_event, severity: "major")).to be_actionable
    expect(build(:drift_event, severity: "minor")).not_to be_actionable
  end
end

RSpec.describe ApiKey do
  it "authenticates the raw token once generated and never stores it" do
    key, raw = described_class.generate!(name: "ci")
    expect(key.attributes.values).not_to include(raw)
    expect(described_class.authenticate(raw)).to eq(key)
    expect(key.reload.last_used_at).to be_present
  end

  it "rejects blank, wrong and revoked tokens" do
    key, raw = described_class.generate!(name: "ci")
    expect(described_class.authenticate("")).to be_nil
    expect(described_class.authenticate("pg_nope")).to be_nil
    key.revoke!
    expect(described_class.authenticate(raw)).to be_nil
  end
end
