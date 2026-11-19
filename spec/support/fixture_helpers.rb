module FixtureHelpers
  SERP_DIR = Rails.root.join("spec/fixtures/serp")

  def serp_fixture(name, engine: "google")
    File.binread(SERP_DIR.join(engine, "#{name}.html")).force_encoding(Encoding::UTF_8)
  end
end

RSpec.configure { |c| c.include FixtureHelpers }
