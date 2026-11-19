require "rails_helper"

RSpec.describe Contracts::SelectorPolicy do
  {
    "h3" => nil,
    "div.kb0PBd > a[href]" => nil,
    'a[href*="x"]' => nil,
    "" => "is empty",
    "*" => "may not use the universal selector *",
    "div * * a" => "may not use the universal selector *",
    "div:has(a:has(b))" => "may not nest :has",
    "a b c d e f g h i" => "may not combine more than 8 compound selectors",
    "h3[[" => "is not valid CSS",
    "a" * 201 => "is longer than 200 characters"
  }.each do |selector, reason|
    it "#{selector.truncate(20).inspect} -> #{reason.inspect}" do
      expect(described_class.violation(selector)).to eq(reason)
    end
  end

  it "is enforced on contracts and accepted suggestions" do
    contract = build(:parser_contract, container_selector: "div *")
    expect(contract).not_to be_valid
    expect(contract.errors[:container_selector].join).to include("universal")

    suggestion = create(:selector_suggestion)
    expect(Healing::SuggestionAcceptor.call(suggestion, selector: "* *").error_message).to include("universal")
    expect(suggestion.reload.status).to eq("pending")
  end
end

RSpec.describe Html::Normalizer do
  it "refuses absurdly deep documents" do
    html = "<div>" * 400 + "x" + "</div>" * 400
    expect { described_class.call(html) }.to raise_error(Html::Normalizer::TooDeep)
    result = Ingestion::SnapshotCreator.call(html:, engine: "google", source: "api")
    expect(result.error_message).to include("deeper than")
  end
end

RSpec.describe Healing::TextMatcher do
  it "bounds work on hostile pages full of near-length decoys" do
    sample = "ruby web scraping guide with nokogiri and faraday for beginners"
    decoys = Array.new(3_000) { |i| "<p>#{('x' * 60)}#{i}</p>" }.join
    doc = Nokogiri::HTML5("<div>#{decoys}<h3>#{sample}</h3></div>")

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    node = described_class.find([ doc.root ], sample)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    expect(node.name).to eq("h3")
    expect(elapsed).to be < 2.0
  end

  it "banded Levenshtein agrees with the full one within the band" do
    expect(described_class.levenshtein("kitten", "sitting", 3)).to eq(3)
    expect(described_class.levenshtein("kitten", "sitting", 2)).to be_nil
    expect(described_class.similarity("abcdefghij", "abcdefghix", min: 0.85)).to eq(0.9)
  end

  it "stops after the node budget" do
    doc = Nokogiri::HTML5("<div>#{'<p>a</p>' * 50}<h3>target</h3></div>")
    expect(described_class.find([ doc.root ], "target", max_nodes: 10)).to be_nil
  end
end

RSpec.describe Alerts::SlackPayload do
  it "escapes mrkdwn control sequences from untrusted fields" do
    event = build(:drift_event, severity: "major",
                                broken_fields: [ { "contract" => "google/x<!channel>", "field" => "t`x", "rate" => 0 } ])
    event.locale = "en <https://evil.test|login>"
    text = described_class.call(event, app_url: nil)[:blocks].first.dig(:text, :text)

    expect(text).not_to include("<!channel>", "<https://evil.test")
    expect(text).to include("&lt;!channel&gt;", "&lt;https://evil.test|login&gt;", "t'x")
  end
end

RSpec.describe Snapshot do
  it "rejects locales that are not language tags" do
    expect(build(:snapshot, locale: "en-US <!channel>")).not_to be_valid
    expect(build(:snapshot, locale: "pt-BR")).to be_valid
  end
end

RSpec.describe Healing::SuggestionAcceptor do
  it "lets only one of two racing accepts apply" do
    contract = create(:parser_contract)
    suggestion = create(:selector_suggestion, contract:, candidates: [ { "selector" => "h3.a" } ])
    stale_copy = SelectorSuggestion.find(suggestion.id)

    expect(described_class.call(suggestion)).to be_ok
    second = described_class.call(stale_copy, selector: "h3.b")

    expect(second).to be_failure
    expect(second.error_message).to include("already accepted")
    expect(contract.reload.version).to eq(2)
    expect(contract.field_spec("title").selector).to eq("h3.a")
  end
end

RSpec.describe "Dashboard auth outside development", type: :request do
  it "refuses to serve without a password" do
    allow(Rails.env).to receive(:local?).and_return(false)
    get "/"
    expect(response).to have_http_status(:service_unavailable)
  end
end
