# Declares how one result type (e.g. google/organic_results) is extracted:
# a container selector plus per-field selectors evaluated inside each container.
class ParserContract
  include Mongoid::Document
  include Mongoid::Timestamps

  CONTAINER_FIELD = "_container".freeze

  field :engine, type: String
  field :result_type, type: String
  field :scope_selector, type: String, default: "body"
  field :container_selector, type: String
  field :min_extraction_rate, type: Float, default: 0.9
  field :version, type: Integer, default: 1
  field :active, type: Boolean, default: true

  embeds_many :fields, class_name: "FieldSpec", cascade_callbacks: true
  embeds_many :revisions, class_name: "ContractRevision"
  has_many :contract_runs, inverse_of: :contract, dependent: :destroy
  has_many :selector_suggestions, inverse_of: :contract, dependent: :destroy

  index({ engine: 1, result_type: 1 }, { unique: true })

  validates :engine, :result_type, :container_selector, presence: true
  validates :result_type, uniqueness: { scope: :engine }
  validates :min_extraction_rate, numericality: { greater_than: 0, less_than_or_equal_to: 1 }
  validate :field_names_unique

  scope :active, -> { where(active: true) }

  def key = "#{engine}/#{result_type}"

  def field_spec(name) = fields.detect { |f| f.name == name.to_s }

  def required_fields = fields.select(&:required)

  # Current selector for a field name, or the container selector for "_container".
  def selector_for(name)
    name.to_s == CONTAINER_FIELD ? container_selector : field_spec(name)&.selector
  end

  private

  def field_names_unique
    dupes = fields.map(&:name).tally.select { |_, n| n > 1 }.keys
    errors.add(:fields, "duplicate names: #{dupes.join(', ')}") if dupes.any?
  end
end
