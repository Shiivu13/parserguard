module Html
  # Converts captured bytes to UTF-8 before anything is hashed, stored or
  # parsed. Order: valid UTF-8 as-is, then the declared charset (HTTP header
  # or <meta>), then Windows-1252 (what browsers assume for unlabeled pages).
  module Encoding
    META_CHARSET = /<meta[^>]+charset\s*=\s*["']?\s*([A-Za-z0-9_.:-]+)/i
    FALLBACK = "Windows-1252".freeze

    module_function

    def to_utf8(raw, charset: nil)
      bytes = raw.to_s.b
      utf8 = bytes.dup.force_encoding(::Encoding::UTF_8)
      return utf8 if utf8.valid_encoding?

      source = lookup(charset) || lookup(bytes[0, 4096][META_CHARSET, 1]) || ::Encoding.find(FALLBACK)
      source = ::Encoding.find(FALLBACK) if source == ::Encoding::UTF_8
      bytes.force_encoding(source).encode(::Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "\uFFFD")
    end

    def lookup(name)
      return nil if name.blank?

      enc = ::Encoding.find(name.to_s.strip)
      # Browsers treat ISO-8859-1 labels as Windows-1252.
      enc == ::Encoding::ISO_8859_1 ? ::Encoding.find(FALLBACK) : enc
    rescue ArgumentError
      nil
    end
  end
end
