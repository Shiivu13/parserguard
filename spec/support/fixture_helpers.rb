module FixtureHelpers
  SERP_DIR = Rails.root.join("spec/fixtures/serp")

  def serp_fixture(name, engine: "google")
    File.binread(SERP_DIR.join(engine, "#{name}.html")).force_encoding(Encoding::UTF_8)
  end

  def serp_doc(name, engine: "google") = Html::Normalizer.call(serp_fixture(name, engine:))

  # Imports all google fixtures; returns { "baseline" => Snapshot, ... }.
  def import_google_fixtures
    Ingestion::FixtureImporter.call(dir: SERP_DIR.join("google")).to_h do |result|
      [ result.value.source_ref.delete_suffix(".html"), result.value ]
    end
  end

  def google_contract
    Contracts::Loader.call
    ParserContract.find_by(engine: "google", result_type: "organic_results")
  end
end

RSpec.configure { |c| c.include FixtureHelpers }
