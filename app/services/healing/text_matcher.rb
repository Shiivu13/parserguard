module Healing
  # Finds where a known-good value lives in a new DOM.
  #
  # Text: normalize (downcase, strip punctuation, squish), exact match first,
  #       else Levenshtein similarity >= min_similarity. Deepest node wins ties.
  # URL:  compare host (minus www.) + path of href.
  module TextMatcher
    module_function

    def normalize(value) = value.to_s.downcase.gsub(/[[:punct:]]+/, " ").squish

    def url_key(value)
      ok, url = Contracts::TypeValidator.url(value, Contracts::TypeValidator::DEFAULT_BASE)
      return nil unless ok

      uri = URI.parse(url)
      "#{uri.host.downcase.delete_prefix('www.')}#{uri.path.chomp('/')}"
    rescue URI::Error
      nil
    end

    def similarity(a, b)
      return 1.0 if a == b
      return 0.0 if a.empty? || b.empty?

      longer = [ a.length, b.length ].max
      # Cheap reject: a length gap this big can never reach a useful similarity.
      return 0.0 if (a.length - b.length).abs.to_f / longer > 0.2

      1.0 - levenshtein(a, b).to_f / longer
    end

    def same?(sample, value, url: false, min_similarity: 0.85)
      if url
        key = url_key(sample)
        key.present? && key == url_key(value)
      else
        similarity(normalize(sample), normalize(value)) >= min_similarity
      end
    end

    # Deepest element under `roots` whose text (or href) best matches `value`.
    def find(roots, value, url: false, min_similarity: 0.85, max_length: 300)
      target = url ? url_key(value) : normalize(value)
      return nil if target.blank?

      best = nil
      best_score = 0.0
      Array(roots).each do |root|
        # traverse is post-order: children are visited before parents, so on a
        # tie the deeper node is kept (we only replace on a strictly better score).
        root.traverse do |node|
          next unless node.element?

          score = url ? url_score(node, target) : text_score(node, target, max_length)
          next unless score >= (url ? 1.0 : min_similarity) && score > best_score

          best = node
          best_score = score
          break if score == 1.0 && url
        end
      end
      best
    end

    def text_score(node, target, max_length)
      text = node.text
      return 0.0 if text.length > max_length * 2

      candidate = normalize(text)
      return 0.0 if candidate.empty? || candidate.length > max_length

      similarity(target, candidate)
    end

    def url_score(node, target)
      href = node["href"]
      href && url_key(href) == target ? 1.0 : 0.0
    end

    def levenshtein(a, b)
      prev = (0..b.length).to_a
      a.each_char.with_index(1) do |ca, i|
        curr = [ i ]
        b.each_char.with_index(1) do |cb, j|
          curr << [ prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + (ca == cb ? 0 : 1) ].min
        end
        prev = curr
      end
      prev.last
    end
  end
end
