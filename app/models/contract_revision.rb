# Audit trail entry: a selector changed (usually via an accepted suggestion).
# field_name "_container" means the contract's container_selector changed.
class ContractRevision
  include Mongoid::Document

  field :field_name, type: String
  field :from_selector, type: String
  field :to_selector, type: String
  field :version, type: Integer
  field :suggestion_id, type: BSON::ObjectId
  field :at, type: Time, default: -> { Time.current }

  embedded_in :parser_contract
end
