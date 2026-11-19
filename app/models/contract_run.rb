# Result of running one contract against one snapshot.
class ContractRun
  include Mongoid::Document
  include Mongoid::Timestamps

  STATUSES = %w[passed failed].freeze
  MAX_ITEMS = 50

  belongs_to :contract, class_name: "ParserContract", inverse_of: :contract_runs
  belongs_to :snapshot

  field :contract_version, type: Integer
  field :container_count, type: Integer, default: 0
  field :items, type: Array, default: []
  # [{ "name", "present", "valid", "rate" }]
  field :field_stats, type: Array, default: []
  # [{ "item", "field", "message" }]
  field :validation_errors, type: Array, default: []
  field :extraction_rate, type: Float, default: 0.0
  field :status, type: String
  field :duration_ms, type: Integer

  index({ contract_id: 1, created_at: -1 })
  index({ snapshot_id: 1 })
  index({ status: 1 })

  validates :status, inclusion: { in: STATUSES }

  scope :recent, -> { order_by(created_at: :desc) }

  def passed? = status == "passed"

  def field_rate(name)
    stat = field_stats.detect { |s| s["name"] == name.to_s }
    stat ? stat["rate"].to_f : 0.0
  end

  def failing_fields(threshold)
    field_stats.select { |s| s["required"] && s["rate"].to_f < threshold }.map { |s| s["name"] }
  end
end
