require "rails_helper"

RSpec.describe Healing::TextMatcher do
  it "normalizes case, punctuation and whitespace" do
    expect(described_class.normalize("  Ruby — Programming,  Language! ")).to eq("ruby programming language")
  end

  it "computes Levenshtein similarity" do
    expect(described_class.levenshtein("kitten", "sitting")).to eq(3)
    expect(described_class.similarity("abcd", "abcd")).to eq(1.0)
    expect(described_class.similarity("abcdefghij", "abcdefghix")).to eq(0.9)
    expect(described_class.similarity("short", "a much longer string", min: 0.85)).to eq(0.0)
  end

  it "keys URLs by host and path" do
    expect(described_class.url_key("https://www.Nokogiri.org/tutorials/")).to eq("nokogiri.org/tutorials")
    expect(described_class.url_key("/url?q=https://nokogiri.org/tutorials&sa=U")).to eq("nokogiri.org/tutorials")
    expect(described_class.url_key("javascript:void(0)")).to be_nil
  end

  it "finds the deepest node with matching text, tolerating small edits" do
    doc = Nokogiri::HTML5("<div><a href='/x'><h3>Ruby Programming Language</h3></a></div>")
    expect(described_class.find([ doc.root ], "Ruby Programming Language").name).to eq("h3")
    expect(described_class.find([ doc.root ], "Ruby Programming Languages").name).to eq("h3")
    expect(described_class.find([ doc.root ], "Python")).to be_nil
  end

  it "finds anchors by URL" do
    doc = Nokogiri::HTML5("<div><a href='https://nokogiri.org/'>N</a></div>")
    expect(described_class.find([ doc.root ], "https://www.nokogiri.org", url: true)["href"]).to eq("https://nokogiri.org/")
  end
end

RSpec.describe Healing::SelectorGenerator do
  let(:doc) do
    Nokogiri::HTML5(<<~HTML)
      <div class="item"><div class="kb0PBd" data-sncf="1"><h3 id="t-9381772" class="DKV0Md title">T</h3></div></div>
    HTML
  end
  let(:container) { doc.at_css("div.item") }
  let(:candidates) { described_class.call(doc.at_css("h3"), root: container) }
  let(:by_selector) { candidates.index_by(&:selector) }

  it "flags build-generated class names" do
    expect(described_class.obfuscated?("yuRUbf")).to be(true)
    expect(described_class.obfuscated?("tF2Cxc")).to be(true)
    expect(described_class.obfuscated?("title")).to be(false)
    expect(described_class.obfuscated?("g")).to be(false)
  end

  it "ranks semantic tags and readable classes above obfuscated ones" do
    expect(by_selector["h3"].stability).to eq(0.8)
    expect(by_selector["h3.title"].stability).to eq(0.7)
    expect(by_selector["h3.DKV0Md"].stability).to eq(0.5)
  end

  it "rejects random-looking ids" do
    expect(candidates.map(&:selector)).not_to include("#t-9381772")
  end

  it "builds parent chains, data-attribute and nth-of-type candidates" do
    expect(by_selector["div[data-sncf] > h3"]).to have_attributes(kind: "chain", stability: 0.7)
    expect(by_selector["div.kb0PBd > h3"].stability).to eq(0.5)
    expect(by_selector["div:nth-of-type(1) > h3:nth-of-type(1)"].stability).to eq(0.3)
  end
end

RSpec.describe Healing::CandidateScorer do
  it "computes confidence from the weighted formula" do
    expect(described_class.confidence(coverage: 1.0, agreement: 0.5, stability: 0.8, uniqueness: 0.5)).to eq(0.76)
  end

  it "collapses candidates that select the same nodes, keeping the most stable" do
    doc = Nokogiri::HTML5("<div class='c'><h3 class='x'>A</h3></div><div class='c'><h3 class='x'>B</h3></div>")
    gen = Healing::SelectorGenerator::Candidate
    rows = described_class.call(
      [ gen.new("h3.x", "class", 0.5), gen.new("h3", "tag", 0.8) ],
      containers: doc.css("div.c").to_a, samples: %w[A B], extract: "text", value_type: "string"
    )
    expect(rows.map { |r| r["selector"] }).to eq([ "h3" ])
    expect(rows.first).to include("coverage" => 1.0, "agreement" => 1.0, "uniqueness" => 1.0, "confidence" => 0.96)
  end
end

RSpec.describe Healing::Healer do
  let!(:contract) { google_contract }
  let!(:snaps) { import_google_fixtures }

  def heal(field, snapshot) = described_class.call(contract:, field_name: field, snapshot: snaps[snapshot])

  it "suggests stable selectors for renamed classes" do
    { "title" => "h3", "link" => "a[href]" }.each do |field, expected|
      suggestion = heal(field, "class_rename").value
      expect(suggestion.top_candidate).to include("selector" => expected)
      expect(suggestion.top_candidate["confidence"]).to be >= 0.9
      expect(suggestion.old_selector).to eq(contract.selector_for(field))
    end
  end

  it "stores the baseline run it sampled from" do
    expect { heal("title", "class_rename") }.to change { ContractRun.where(snapshot_id: snaps["baseline"].id).count }.by(1)
    expect { heal("snippet", "class_rename") }.not_to(change { ContractRun.count })
  end

  it "heals a structural change in two steps: container, then broken field" do
    container = heal("_container", "structural_change").value
    expect(container.top_candidate).to include("selector" => "div.MjjYud")
    Healing::SuggestionAcceptor.call(container)

    link = described_class.call(contract: contract.reload, field_name: "link", snapshot: snaps["structural_change"]).value
    Healing::SuggestionAcceptor.call(link)

    rate = Contracts::Runner.evaluate(contract.reload, serp_doc("structural_change")).extraction_rate
    expect(rate).to be >= 0.9
  end

  it "returns no candidates for a page without results" do
    suggestion = heal("_container", "broken").value
    expect(suggestion.candidates).to eq([])
  end

  it "reuses a pending suggestion for the same snapshot and field" do
    first = heal("title", "class_rename")
    second = heal("title", "class_rename")
    expect(second.meta[:created]).to be(false)
    expect(second.value.id).to eq(first.value.id)
  end

  it "rejects unknown fields and targets without a baseline" do
    expect(heal("price", "class_rename").error_message).to eq("unknown field price")
    snaps["baseline"].set(baseline: false)
    expect(heal("title", "class_rename").error_message).to start_with("no baseline")
  end
end

RSpec.describe Healing::SuggestionAcceptor do
  let(:contract) { create(:parser_contract) }
  let(:suggestion) { create(:selector_suggestion, contract:, field_name: "title", old_selector: "h3") }

  it "applies the top candidate, bumps the version and records a revision" do
    suggestion.update!(candidates: [ { "selector" => "h3.new", "confidence" => 0.9 } ])
    result = described_class.call(suggestion)

    expect(result).to be_ok
    contract.reload
    expect(contract.field_spec("title").selector).to eq("h3.new")
    expect(contract.version).to eq(2)
    expect(contract.revisions.last).to have_attributes(field_name: "title", from_selector: "h3", to_selector: "h3.new", version: 2)
    expect(suggestion.reload).to have_attributes(status: "accepted", accepted_selector: "h3.new")
  end

  it "accepts an explicit selector and rejects siblings for the same snapshot only" do
    snapshot = create(:snapshot)
    suggestion.update!(snapshot:)
    sibling = create(:selector_suggestion, contract:, field_name: "title", snapshot:)
    other_layout = create(:selector_suggestion, contract:, field_name: "title", snapshot: create(:snapshot))
    described_class.call(suggestion, selector: "div > h3")

    expect(contract.reload.field_spec("title").selector).to eq("div > h3")
    expect(sibling.reload.status).to eq("rejected")
    expect(other_layout.reload.status).to eq("pending")
  end

  it "updates the container selector for container suggestions" do
    s = create(:selector_suggestion, contract:, field_name: "_container", candidates: [ { "selector" => "div.item" } ])
    described_class.call(s)
    expect(contract.reload.container_selector).to eq("div.item")
  end

  it "refuses invalid CSS, empty candidates and already-decided suggestions" do
    expect(described_class.call(suggestion, selector: "h3[[").error_message).to include("not valid CSS")

    suggestion.update!(candidates: [])
    expect(described_class.call(suggestion).error_message).to eq("no selector to apply")

    suggestion.update!(status: "rejected")
    expect(described_class.call(suggestion, selector: "h3").error_message).to include("already rejected")
    expect(contract.reload.version).to eq(1)
  end
end
