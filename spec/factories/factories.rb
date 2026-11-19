FactoryBot.define do
  factory :snapshot do
    engine { "google" }
    query { "ruby web scraping" }
    locale { "en-US" }
    device { "desktop" }
    source { "fixture" }
    sequence(:version) { |n| n }
    sequence(:html) { |n| "<html><body><div id=\"rso\"><p>page #{n}</p></div></body></html>" }
  end

  factory :field_spec do
    name { "title" }
    selector { "h3" }
    extract { "text" }
    required { true }
    value_type { "string" }
  end

  factory :parser_contract do
    engine { "google" }
    sequence(:result_type) { |n| "organic_results_#{n}" }
    container_selector { "#rso div.g" }
    min_extraction_rate { 0.9 }
    field_specs do
      [
        build(:field_spec, name: "title", selector: "h3"),
        build(:field_spec, name: "link", selector: "a[href]", extract: "href", value_type: "url"),
        build(:field_spec, name: "snippet", selector: "div.VwiC3b", required: false)
      ]
    end
  end

  factory :contract_run do
    association :contract, factory: :parser_contract
    snapshot
    contract_version { 1 }
    container_count { 4 }
    extraction_rate { 1.0 }
    status { "passed" }
  end

  factory :drift_event do
    association :baseline_snapshot, factory: :snapshot
    association :candidate_snapshot, factory: :snapshot
    engine { "google" }
    locale { "en-US" }
    device { "desktop" }
    drift_score { 0.1 }
    tag_drift { 0.1 }
    class_drift { 0.1 }
    severity { "minor" }
  end

  factory :selector_suggestion do
    association :contract, factory: :parser_contract
    field_name { "title" }
    old_selector { "h3.LC20lb" }
    candidates { [ { "selector" => "h3", "kind" => "tag", "confidence" => 0.9 } ] }
  end
end
