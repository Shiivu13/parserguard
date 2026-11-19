# One extractable field inside a parser contract.
class FieldSpec
  include Mongoid::Document

  VALUE_TYPES = %w[string url integer].freeze

  field :name, type: String
  field :selector, type: String
  # "text" = node text; anything else is read as an attribute ("href", "src", ...).
  field :extract, type: String, default: "text"
  field :required, type: Boolean, default: true
  field :value_type, type: String, default: "string"

  embedded_in :parser_contract

  validates :name, presence: true, format: { with: /\A[a-z_][a-z0-9_]*\z/ }
  validates :selector, presence: true
  validates :value_type, inclusion: { in: VALUE_TYPES }
  validates :extract, format: { with: /\A[a-z][a-z0-9_-]{0,40}\z/ }
  validate :selector_allowed

  private

  def selector_allowed
    return if selector.blank?

    reason = Contracts::SelectorPolicy.violation(selector)
    errors.add(:selector, reason) if reason
  end
end
