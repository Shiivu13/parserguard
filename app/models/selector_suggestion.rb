# Ranked replacement selectors for one broken field. Never auto-applied:
# a human accepts one through the dashboard or API.
class SelectorSuggestion
  include Mongoid::Document
  include Mongoid::Timestamps

  # "accepting" is a short-lived claim held while the contract is updated.
  # A claim older than CLAIM_TTL (process died mid-accept) counts as pending again.
  STATUSES = %w[pending accepting accepted rejected].freeze
  CLAIM_TTL = 2.minutes

  belongs_to :contract, class_name: "ParserContract", inverse_of: :selector_suggestions
  belongs_to :drift_event, optional: true
  belongs_to :snapshot, optional: true

  field :field_name, type: String
  field :old_selector, type: String
  # [{ "selector", "kind", "confidence", "coverage", "agreement", "stability", "uniqueness", "samples" }]
  field :candidates, type: Array, default: []
  field :status, type: String, default: "pending"
  field :claimed_at, type: Time
  field :accepted_selector, type: String
  field :accepted_at, type: Time

  index({ contract_id: 1, status: 1 })
  index({ drift_event_id: 1 })
  # At most one open suggestion per field per snapshot, even under concurrent healers.
  index({ contract_id: 1, field_name: 1, snapshot_id: 1 },
        { unique: true, name: "one_pending_per_field_snapshot",
          partial_filter_expression: { status: "pending", snapshot_id: { "$type" => "objectId" } } })

  validates :field_name, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :pending, -> { any_of({ status: "pending" }, { status: "accepting", :claimed_at.lt => CLAIM_TTL.ago }) }
  scope :recent, -> { order_by(created_at: :desc) }

  def self.claimable(id) = pending.where(_id: id)

  def top_candidate = candidates.first
  def container? = field_name == ParserContract::CONTAINER_FIELD

  def pending?
    status == "pending" || (status == "accepting" && claimed_at && claimed_at < CLAIM_TTL.ago)
  end

  # Atomic pending -> accepting. True only for the caller that won.
  def claim!
    claimed = self.class.claimable(id).find_one_and_update({ "$set" => { status: "accepting", claimed_at: Time.current } })
    reload if claimed
    claimed.present?
  end

  def release_claim!
    self.class.where(_id: id, status: "accepting").update_all(status: "pending", claimed_at: nil)
    reload
  end

  # Atomic pending -> rejected; false if someone accepted or rejected it first.
  def reject!
    rejected = self.class.claimable(id).find_one_and_update({ "$set" => { status: "rejected" } })
    reload
    rejected.present?
  end
end
