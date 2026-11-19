require "zlib"
require "digest"

# A captured SERP page. HTML is stored gzipped; structural histograms are
# precomputed at ingest so drift comparison never re-parses old pages.
class Snapshot
  include Mongoid::Document
  include Mongoid::Timestamps

  DEVICES = %w[desktop mobile].freeze
  SOURCES = %w[fixture url serpapi api].freeze

  field :engine, type: String
  field :query, type: String
  field :locale, type: String, default: "en-US"
  field :device, type: String, default: "desktop"
  field :source, type: String
  field :source_ref, type: String
  field :version, type: Integer
  field :captured_at, type: Time, default: -> { Time.current }
  field :html_gz, type: BSON::Binary
  field :byte_size, type: Integer
  field :sha256, type: String
  # Arrays of [path, count] pairs: CSS paths contain "." which Mongo keys forbid.
  field :tag_histogram, type: Array, default: []
  field :class_histogram, type: Array, default: []
  field :baseline, type: Boolean, default: false

  has_many :contract_runs, dependent: :destroy

  index({ engine: 1, locale: 1, device: 1, captured_at: -1 })
  index({ engine: 1, locale: 1, device: 1, version: 1 }, { unique: true })
  index({ engine: 1, locale: 1, device: 1, sha256: 1 }, { unique: true, name: "one_capture_per_target" })
  index({ engine: 1, locale: 1, device: 1 },
        { unique: true, name: "one_baseline_per_target", partial_filter_expression: { baseline: true } })

  validates :engine, presence: true, format: { with: /\A[a-z0-9_]+\z/ }
  validates :device, inclusion: { in: DEVICES }
  validates :locale, format: { with: /\A[a-z]{2,3}(-[A-Za-z0-9]{2,8})*\z/ }
  validates :source, inclusion: { in: SOURCES }
  validates :version, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :sha256, presence: true
  validates :html_gz, presence: true

  scope :light, -> { without(:html_gz) }
  scope :for_target, ->(engine, locale, device) { where(engine:, locale:, device:) }
  scope :recent, -> { order_by(captured_at: :desc) }

  def self.digest(html) = Digest::SHA256.hexdigest(html.to_s.b)

  def self.next_version(engine, locale, device)
    (for_target(engine, locale, device).max(:version) || 0) + 1
  end

  # Light document (no HTML). Use #with_html when the page itself is needed.
  def self.baseline_for(engine, locale, device)
    for_target(engine, locale, device).where(baseline: true).light.first
  end

  def html=(raw)
    raw = raw.to_s
    self.html_gz = BSON::Binary.new(Zlib.gzip(raw.b))
    self.byte_size = raw.bytesize
    self.sha256 = self.class.digest(raw)
    @html = nil
  end

  def html
    return nil if html_gz.nil?

    @html ||= Zlib.gunzip(html_gz.data).force_encoding(Encoding::UTF_8).scrub("\uFFFD")
  end

  # Full document including HTML (self when already loaded).
  def with_html
    attribute_missing?("html_gz") ? self.class.find(id) : self
  end

  def target = [ engine, locale, device ]

  def label = "#{engine} #{locale}/#{device} v#{version}"

  def promote_to_baseline!
    self.class.for_target(*target).where(baseline: true).not.where(_id: id).update_all(baseline: false)
    set(baseline: true)
  end
end
