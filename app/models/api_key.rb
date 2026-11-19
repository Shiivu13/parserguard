require "digest"

# API credential. Only the SHA256 digest is stored; the raw token is shown once.
class ApiKey
  include Mongoid::Document
  include Mongoid::Timestamps

  TOKEN_PREFIX = "pg_".freeze

  field :name, type: String
  field :token_digest, type: String
  field :prefix, type: String
  field :last_used_at, type: Time
  field :revoked_at, type: Time

  index({ token_digest: 1 }, { unique: true })

  validates :name, :token_digest, presence: true

  scope :active, -> { where(revoked_at: nil) }

  # Returns [api_key, raw_token]. The raw token is never persisted.
  def self.generate!(name:)
    raw = TOKEN_PREFIX + SecureRandom.urlsafe_base64(32)
    key = create!(name:, token_digest: digest(raw), prefix: raw[0, 10])
    [ key, raw ]
  end

  def self.digest(raw) = Digest::SHA256.hexdigest(raw.to_s)

  def self.authenticate(raw)
    return nil if raw.blank?

    wanted = digest(raw)
    candidate = active.where(token_digest: wanted).first
    return nil unless candidate && ActiveSupport::SecurityUtils.secure_compare(candidate.token_digest, wanted)

    candidate.set(last_used_at: Time.current)
    candidate
  end

  def revoke! = update!(revoked_at: Time.current)
end
