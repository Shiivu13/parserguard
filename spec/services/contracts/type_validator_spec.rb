require "rails_helper"

RSpec.describe Contracts::TypeValidator do
  {
    [ "  Hello\n world ", "string" ] => [ true, "Hello world" ],
    [ "   ", "string" ] => [ false, nil ],
    [ nil, "string" ] => [ false, nil ],
    [ "About 1,230,000 results", "integer" ] => [ true, 1_230_000 ],
    [ "none", "integer" ] => [ false, nil ],
    [ "https://ruby-lang.org/en/", "url" ] => [ true, "https://ruby-lang.org/en/" ],
    [ "/url?q=https://nokogiri.org/&sa=U", "url" ] => [ true, "https://nokogiri.org/" ],
    [ "/search?q=ruby", "url" ] => [ true, "https://www.google.com/search?q=ruby" ],
    [ "javascript:alert(1)", "url" ] => [ false, nil ],
    [ "mailto:a@b.c", "url" ] => [ false, nil ],
    [ "http://exa mple.com", "url" ] => [ false, nil ],
    [ "x", "date" ] => [ false, nil ]
  }.each do |(value, type), expected|
    it "#{type}: #{value.inspect} -> #{expected.inspect}" do
      expect(described_class.call(value, type)).to eq(expected)
    end
  end
end

RSpec.describe Contracts::FieldExtractor do
  let(:container) { Nokogiri::HTML5.fragment('<div><a href="/x"><h3>T</h3></a><h3>U</h3></div>').at_css("div") }

  it "extracts text or attributes" do
    expect(described_class.call(container, selector: "h3").first).to eq("T")
    expect(described_class.call(container, selector: "a", extract: "href").first).to eq("/x")
    expect(described_class.all(container, selector: "h3")).to eq(%w[T U])
  end

  it "treats invalid CSS as not found" do
    expect(described_class.call(container, selector: "h3[[").first).to be_nil
    expect(described_class.all(container, selector: "h3[[")).to eq([])
  end
end
