require "rails_helper"

# Every expectation in spec/fixtures/serp/*/manifest.yml must hold.
# Same runner as `bin/rails parserguard:regression`, so CI and local agree.
RSpec.describe Regression::Runner do
  before(:all) { @report = described_class.call }

  it "produces checks for every fixture" do
    expect(@report.map(&:fixture).uniq).to eq(%w[baseline.html ads_added.html class_rename.html structural_change.html broken.html])
    expect(@report.size).to be >= 12
  end

  it "meets every manifest expectation" do
    failures = @report.reject(&:ok).map { |c| "#{c.fixture} #{c.check}: expected #{c.expected}, got #{c.actual}" }
    expect(failures).to be_empty, failures.join("\n")
  end

  it "heals both layout changes back above the contract minimum" do
    healed = @report.select { |c| c.check == "healed_rate" }
    expect(healed.map(&:fixture)).to contain_exactly("class_rename.html", "structural_change.html")
    expect(healed.map(&:actual)).to all(be >= 0.9)
  end

  it "uses a scratch database and leaves app data alone" do
    expect(Mongoid.default_client.database.name).not_to start_with("parserguard_regression_")
    names = Mongoid.default_client.database_names
    expect(names.grep(/\Aparserguard_regression_#{Process.pid}_/)).to be_empty
  end

  it "fails a check when an expectation is not met" do
    Dir.mktmpdir do |dir|
      engine_dir = File.join(dir, "google")
      FileUtils.mkdir_p(engine_dir)
      File.write(File.join(engine_dir, "baseline.html"), serp_fixture("baseline"))
      File.write(File.join(engine_dir, "manifest.yml"), {
        "fixtures" => [ { "file" => "baseline.html", "expect" => { "organic_results_rate" => [ 0.0, 0.5 ] } } ]
      }.to_yaml)

      report = described_class.call(root: dir)
      expect(report.map(&:ok)).to eq([ false ])
      expect(report.first.actual).to eq(1.0)
    end
  end
end
