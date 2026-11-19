module Contracts
  # Runs a contract against a snapshot.
  #
  #   containers = doc.css(scope).css(container_selector)
  #   rate       = valid required cells / (containers * required fields)
  #   field rate = valid cells for that field / containers
  #
  # .evaluate is pure (no writes) so healing can score hypothetical contracts.
  class Runner
    MAX_ERRORS = 100

    Evaluation = Data.define(:container_count, :items, :field_stats, :validation_errors, :extraction_rate) do
      def status_for(contract) = extraction_rate >= contract.min_extraction_rate ? "passed" : "failed"
    end

    def self.call(contract, snapshot, doc: nil)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      evaluation = evaluate(contract, doc || Html::Normalizer.call(snapshot.html))
      elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round

      ContractRun.create!(
        contract:, snapshot:,
        contract_version: contract.version,
        container_count: evaluation.container_count,
        items: evaluation.items.first(ContractRun::MAX_ITEMS),
        field_stats: evaluation.field_stats,
        validation_errors: evaluation.validation_errors,
        extraction_rate: evaluation.extraction_rate,
        status: evaluation.status_for(contract),
        duration_ms: elapsed
      )
    end

    def self.evaluate(contract, doc) = new(contract, doc).evaluate

    def self.containers(doc, contract, container_selector: contract.container_selector)
      doc.css(contract.scope_selector.presence || "body").flat_map { |scope| scope.css(container_selector).to_a }.uniq
    rescue Nokogiri::CSS::SyntaxError, Nokogiri::XML::XPath::SyntaxError
      []
    end

    def initialize(contract, doc)
      @contract = contract
      @doc = doc
    end

    def evaluate
      containers = self.class.containers(@doc, @contract)
      specs = @contract.field_specs.to_a
      valid_counts = Hash.new(0)
      present_counts = Hash.new(0)
      errors = []

      items = containers.each_with_index.map do |container, index|
        specs.each_with_object({}) do |spec, item|
          raw, = FieldExtractor.call(container, selector: spec.selector, extract: spec.extract)
          present_counts[spec.name] += 1 unless raw.nil?
          valid, value = TypeValidator.call(raw, spec.value_type)
          if valid
            valid_counts[spec.name] += 1
            item[spec.name] = value
          elsif spec.required && errors.size < MAX_ERRORS
            errors << { "item" => index, "field" => spec.name, "message" => raw.nil? ? "missing" : "invalid #{spec.value_type}" }
          end
        end
      end

      Evaluation.new(
        container_count: containers.size,
        items:,
        field_stats: specs.map { |s| stat(s, containers.size, present_counts, valid_counts) },
        validation_errors: errors,
        extraction_rate: rate(containers.size, specs.select(&:required), valid_counts)
      )
    end

    private

    def stat(spec, total, present, valid)
      {
        "name" => spec.name, "required" => spec.required,
        "present" => present[spec.name], "valid" => valid[spec.name],
        "rate" => total.zero? ? 0.0 : (valid[spec.name].to_f / total).round(4)
      }
    end

    def rate(total, required, valid)
      return 0.0 if total.zero?
      return 1.0 if required.empty?

      cells = required.sum { |s| valid[s.name] }
      (cells.to_f / (total * required.size)).round(4)
    end
  end
end
