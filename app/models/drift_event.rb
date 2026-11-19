# Structural comparison between a baseline and a newer snapshot of the same target.
class DriftEvent
  include Mongoid::Document
  include Mongoid::Timestamps

  SEVERITIES = %w[none minor major broken].freeze

  belongs_to :baseline_snapshot, class_name: "Snapshot", inverse_of: nil
  belongs_to :candidate_snapshot, class_name: "Snapshot", inverse_of: nil
  has_many :selector_suggestions, dependent: :nullify

  field :engine, type: String
  field :locale, type: String
  field :device, type: String
  field :drift_score, type: Float
  field :tag_drift, type: Float
  field :class_drift, type: Float
  # [{ "path", "delta" }]
  field :added_paths, type: Array, default: []
  field :removed_paths, type: Array, default: []
  field :severity, type: String
  # [{ "contract_id", "contract", "field", "rate" }]
  field :broken_fields, type: Array, default: []
  field :alerted_at, type: Time
  field :acknowledged_at, type: Time

  index({ engine: 1, created_at: -1 })
  index({ baseline_snapshot_id: 1, candidate_snapshot_id: 1 }, { unique: true })
  index({ severity: 1 })

  validates :severity, inclusion: { in: SEVERITIES }
  validates :drift_score, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }

  scope :recent, -> { order_by(created_at: :desc) }
  scope :actionable, -> { where(:severity.in => %w[major broken]) }

  def actionable? = %w[major broken].include?(severity)
  def acknowledge! = update!(acknowledged_at: Time.current)
end
