# Uniform return value for service objects.
#   Result.success(snapshot, duplicate: true)
#   Result.failure("timeout")
Result = Data.define(:ok, :value, :errors, :meta) do
  def self.success(value = nil, **meta) = new(ok: true, value:, errors: [], meta:)
  def self.failure(*errors, **meta) = new(ok: false, value: nil, errors: errors.flatten.map(&:to_s), meta:)

  def ok? = ok
  def failure? = !ok
  def error_message = errors.join("; ")
end
