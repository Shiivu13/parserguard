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

  embeds_many :field_specs, class_name: "FieldSpec", cascade_callbacks: true
  embeds_many :revisions, class_name: "ContractRevision"
  has_many :contract_runs, inverse_of: :contract, dependent: :destroy
  has_many :selector_suggestions, inverse_of: :contract, dependent: :destroy

  index({ engine: 1, result_type: 1 }, { unique: true })

  validates :engine, :result_type, :container_selector, presence: true
  validates :engine, :result_type, format: { with: /\A[a-z0-9_]+\z/ }
  validate :selectors_allowed
  validates :result_type, uniqueness: { scope: :engine }
  validates :min_extraction_rate, numericality: { greater_than: 0, less_than_or_equal_to: 1 }
  validate :field_names_unique
  validate { errors.add(:field_specs, "need at least one required field") if field_specs.none?(&:required) }

  scope :active, -> { where(active: true) }

  class ConcurrentUpdate < StandardError; end

  # The only write path for changing an existing contract's definition.
  #
  # Assigning embeds_many on a persisted Mongoid document writes immediately,
  # before validation, and `version += 1; save!` loses bumps under concurrency.
  # So: copy the raw document, let the block edit the copy, validate the
  # result, then write it with a compare-and-set on `version`; retry on conflict.
  #
  #   ParserContract.change!(id) do |doc|      # doc: BSON::Document, string keys
  #     doc["container_selector"] = "div.x"
  #     { revisions: [ { "field_name" => "_container", ... } ], bump: true }
  #   end
  #
  # Returns the saved contract, or an unsaved one carrying errors when invalid.
  def self.change!(id, max_attempts: 5)
    max_attempts.times do
      current = where(_id: id).first
      return nil unless current

      doc = BSON::Document.new(current.as_document.deep_dup)
      outcome = yield(doc) || {}
      bump = outcome.fetch(:bump, true)
      doc["version"] = current.version + (bump ? 1 : 0)
      doc["revisions"] = Array(doc["revisions"]) + Array(outcome[:revisions]).map do |rev|
        ContractRevision.new(rev.merge("version" => doc["version"])).as_document
      end
      doc["updated_at"] = Time.current

      candidate = instantiate(doc)
      return candidate unless candidate.valid?

      saved = where(_id: id, version: current.version)
              .find_one_and_update({ "$set" => doc.except("_id") }, return_document: :after)
      return saved if saved
    end
    raise ConcurrentUpdate, "contract #{id} changed concurrently #{max_attempts} times"
  end

  def key = "#{engine}/#{result_type}"

  def field_spec(name) = field_specs.detect { |f| f.name == name.to_s }

  def required_fields = field_specs.select(&:required)

  # Current selector for a field name, or the container selector for "_container".
  def selector_for(name)
    name.to_s == CONTAINER_FIELD ? container_selector : field_spec(name)&.selector
  end

  private

  def selectors_allowed
    { scope_selector:, container_selector: }.each do |attr, sel|
      next if sel.blank?

      reason = Contracts::SelectorPolicy.violation(sel)
      errors.add(attr, reason) if reason
    end
  end

  def field_names_unique
    dupes = field_specs.map(&:name).tally.select { |_, n| n > 1 }.keys
    errors.add(:field_specs, "duplicate names: #{dupes.join(', ')}") if dupes.any?
  end
end
