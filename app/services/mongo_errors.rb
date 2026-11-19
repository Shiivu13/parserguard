module MongoErrors
  DUPLICATE_KEY = 11_000

  def self.duplicate_key?(error) = error.respond_to?(:code) && error.code == DUPLICATE_KEY
end
