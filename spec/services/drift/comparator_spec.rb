require "rails_helper"

RSpec.describe Drift::Comparator do
  let(:hist) { Struct.new(:tag_histogram, :class_histogram) }

  describe ".weighted_jaccard" do
    it "is 1 for identical and for empty multisets" do
      expect(described_class.weighted_jaccard({ "a" => 2 }, { "a" => 2 })).to eq(1.0)
      expect(described_class.weighted_jaccard({}, {})).to eq(1.0)
    end

    it "is 0 for disjoint multisets" do
      expect(described_class.weighted_jaccard({ "a" => 1 }, { "b" => 1 })).to eq(0.0)
    end

    it "weights by counts" do
      # min: a=1, b=0 -> 1 ; max: a=3, b=1 -> 4
      expect(described_class.weighted_jaccard({ "a" => 3 }, { "a" => 1, "b" => 1 })).to eq(0.25)
    end
  end

  it "combines tag and class drift with configured weights" do
    base = hist.new([ [ "div", 2 ] ], [ [ "div.x", 2 ] ])
    cand = hist.new([ [ "div", 2 ] ], [ [ "div.y", 2 ] ])

    result = described_class.call(base, cand)

    expect(result.tag_drift).to eq(0.0)
    expect(result.class_drift).to eq(1.0)
    expect(result.drift_score).to eq(0.4)
    expect(result.added_paths).to eq([ { "path" => "div.y", "delta" => 2 } ])
    expect(result.removed_paths).to eq([ { "path" => "div.x", "delta" => 2 } ])
  end

  it "sorts path deltas biggest first and caps them" do
    base = hist.new([], [])
    cand = hist.new([], [ [ "a", 1 ], [ "b", 5 ], [ "c", 3 ] ])
    result = described_class.call(base, cand, config: { top_paths: 2 })
    expect(result.added_paths.map { |h| h["path"] }).to eq(%w[b c])
  end

  it "scores the fixtures in the expected order" do
    snaps = import_google_fixtures
    score = ->(name) { described_class.call(snaps["baseline"], snaps[name]).drift_score }

    expect(score.call("baseline")).to eq(0.0)
    expect(score.call("class_rename")).to be < score.call("structural_change")
    expect(score.call("structural_change")).to be <= score.call("broken")
    expect(described_class.call(snaps["baseline"], snaps["class_rename"]).tag_drift).to eq(0.0)
  end
end
