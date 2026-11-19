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

      scalars = data.slice("scope_selector", "container_selector", "min_extraction_rate")
      specs = data.fetch("fields").map { |f| FieldSpec.new(f.slice("name", "selector", "extract", "required", "value_type")) }

      if contract.persisted?
        # Validate-then-write; an invalid YAML must not clobber the stored contract.
        replaced = ParserContract.change!(contract.id) do |doc|
          scalars.each { |k, v| doc[k] = ParserContract.fields[k].mongoize(v) }
          doc["field_specs"] = specs.map(&:as_document)
          {}
        end
        return outcome(replaced, :replaced, path)
      end

      contract.assign_attributes(scalars)
      contract.field_specs = specs
      contract.save
      outcome(contract, :created, path)
    end

    def outcome(contract, action, path)
      return Result.success(contract, action:) if contract.errors.empty?

      Result.failure(contract.errors.full_messages, file: path.basename.to_s)
    end
  end
end
