require "rails_helper"

RSpec.describe Html::StructureSignature do
  def signature(html, **opts)
    described_class.call(Html::Normalizer.call(html), **opts)
  end

  it "counts tag and class paths below the scope" do
    sig = signature(<<~HTML)
      <body><div id="rso"><div class="g b a"><h3>x</h3></div><div class="g"><h3>y</h3></div></div></body>
    HTML

    expect(sig.tag).to include([ "div>div>h3", 2 ], [ "div>div", 2 ], [ "div", 1 ])
    # classes are de-duplicated and sorted so order in markup does not matter
    expect(sig.klass).to include([ "div>div.a.b.g>h3", 1 ], [ "div>div.g>h3", 1 ])
  end

  it "truncates paths to the configured depth" do
    sig = signature("<body><a><b><i><u><s>t</s></u></i></b></a></body>", depth: 2)
    expect(sig.tag.map(&:first)).to include("i>u>s")
    expect(sig.tag.map(&:first)).not_to include("a>b>i>u>s")
  end

  it "ignores scripts, styles and comments" do
    plain = signature("<body><div><p>x</p></div></body>")
    noisy = signature("<body><script>1</script><div><!-- c --><p>x</p><style>p{}</style></div></body>")
    expect(noisy).to eq(plain)
  end

  it "returns empty histograms when the scope is missing and there is no root" do
    sig = described_class.call(Nokogiri::HTML5::DocumentFragment.parse(""), scope: "#nope")
    expect(sig.tag).to eq([])
  end
end
