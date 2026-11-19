module Contracts
  # Loads contract YAML files into Mongo. Existing contracts are left alone
  # unless force: true, so selectors accepted through healing are not
  # silently reverted by a redeploy.
  class Loader
    def self.call(**) = new(**).call

    def initialize(dir: Rails.root.join("config/contracts"), force: false)
      @dir = Pathname(dir)
      @force = force
    end

    def call
      @dir.glob("*.yml").sort.map { |path| load_file(path) }
    end

    private

    def load_file(path)
      data = YAML.safe_load_file(path)
      contract = ParserContract.find_or_initialize_by(engine: data.fetch("engine"), result_type: data.fetch("result_type"))
      return Result.success(contract, action: :skipped) if contract.persisted? && !@force

      action = contract.persisted? ? :replaced : :created
      contract.assign_attributes(data.slice("scope_selector", "container_selector", "min_extraction_rate"))
      contract.field_specs = data.fetch("fields").map { |f| FieldSpec.new(f.slice("name", "selector", "extract", "required", "value_type")) }
      contract.version = (contract.version || 0) + 1 if action == :replaced

      contract.save ? Result.success(contract, action:) : Result.failure(contract.errors.full_messages, file: path.basename.to_s)
    end
  end
end
