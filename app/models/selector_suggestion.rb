# Ranked replacement selectors for one broken field. Never auto-applied:
# a human accepts one through the dashboard or API.
class SelectorSuggestion
  include Mongoid::Document
  include Mongoid::Timestamps

  STATUSES = %w[pending accepted rejected].freeze

  belongs_to :contract, class_name: "ParserContract", inverse_of: :selector_suggestions
  belongs_to :drift_event, optional: true
  belongs_to :snapshot, optional: true

  field :field_name, type: String
  field :old_selector, type: String
  # [{ "selector", "kind", "confidence", "coverage", "agreement", "stability", "uniqueness", "samples" }]
  field :candidates, type: Array, default: []
  field :status, type: String, default: "pending"
  field :accepted_selector, type: String
  field :accepted_at, type: Time

  index({ contract_id: 1, status: 1 })
  index({ drift_event_id: 1 })

  validates :field_name, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :pending, -> { where(status: "pending") }
  scope :recent, -> { order_by(created_at: :desc) }

  def top_candidate = candidates.first
  def pending? = status == "pending"
  def container? = field_name == ParserContract::CONTAINER_FIELD
end
