module Healing
  # Finds where a known-good value lives in a new DOM.
  #
  # Text: normalize (downcase, strip punctuation, squish), exact match first,
  #       else Levenshtein similarity >= min_similarity. Deepest node wins ties.
  # URL:  compare host (minus www.) + path of href.
  #
  # Cost is bounded because captured pages are untrusted: Levenshtein is
  # banded (only distances that could still pass are computed, with early
  # exit), a cheap token-overlap filter runs first, and each search stops
  # after MAX_NODES elements or MAX_FUZZY full comparisons.
  module TextMatcher
    MAX_NODES = 50_000
    MAX_FUZZY = 2_000
    MIN_TOKEN_OVERLAP = 0.5

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

    # 1 - distance / longer length. With min:, returns 0.0 as soon as the
    # result provably falls below it.
    def similarity(a, b, min: 0.0)
      return 1.0 if a == b
      return 0.0 if a.empty? || b.empty?

      longer = [ a.length, b.length ].max
      max_distance = ((1.0 - min) * longer).floor
      distance = levenshtein(a, b, max_distance)
      distance ? 1.0 - distance.to_f / longer : 0.0
    end

    def same?(sample, value, url: false, min_similarity: 0.85)
      if url
        key = url_key(sample)
        key.present? && key == url_key(value)
      else
        similarity(normalize(sample), normalize(value), min: min_similarity) >= min_similarity
      end
    end

    # Deepest element under `roots` whose text (or href) best matches `value`.
    def find(roots, value, url: false, min_similarity: 0.85, max_length: 300, max_nodes: MAX_NODES, max_fuzzy: MAX_FUZZY)
      target = url ? url_key(value) : normalize(value)
      return nil if target.blank?

      state = { best: nil, score: 0.0, nodes: 0, fuzzy: 0, tokens: target.split.to_set }
      Array(roots).each do |root|
        # traverse is post-order: children are visited before parents, so on a
        # tie the deeper node is kept (we only replace on a strictly better score).
        root.traverse do |node|
          next unless node.element?
          break if (state[:nodes] += 1) > max_nodes

          score = url ? url_score(node, target) : text_score(node, target, state, min_similarity, max_length, max_fuzzy)
          next unless score >= (url ? 1.0 : min_similarity) && score > state[:score]

          state[:best] = node
          state[:score] = score
        end
        break if state[:nodes] > max_nodes
      end
      state[:best]
    end

    def text_score(node, target, state, min_similarity, max_length, max_fuzzy)
      text = node.text
      return 0.0 if text.length > max_length * 2

      candidate = normalize(text)
      return 0.0 if candidate.empty? || candidate.length > max_length
      return 1.0 if candidate == target

      longer = [ candidate.length, target.length ].max
      return 0.0 if (candidate.length - target.length).abs > (1.0 - min_similarity) * longer
      return 0.0 if token_overlap(state[:tokens], candidate) < MIN_TOKEN_OVERLAP
      return 0.0 if (state[:fuzzy] += 1) > max_fuzzy

      similarity(target, candidate, min: min_similarity)
    end

    def token_overlap(target_tokens, candidate)
      return 0.0 if target_tokens.empty?

      (target_tokens & candidate.split.to_set).size.to_f / target_tokens.size
    end

    def url_score(node, target)
      href = node["href"]
      href && url_key(href) == target ? 1.0 : 0.0
    end

    # Banded Levenshtein (Ukkonen): only cells with |i - j| <= max are filled,
    # and the search stops once a whole row exceeds max. Returns nil when the
    # distance is greater than max.
    def levenshtein(a, b, max = nil)
      a = a.chars
      b = b.chars
      max ||= [ a.size, b.size ].max
      return nil if (a.size - b.size).abs > max

      inf = max + 1
      prev = Array.new(b.size + 1) { |j| j <= max ? j : inf }
      a.each_with_index do |ca, idx|
        i = idx + 1
        curr = Array.new(b.size + 1, inf)
        curr[0] = i <= max ? i : inf
        row_min = curr[0]
        lo = [ 1, i - max ].max
        hi = [ b.size, i + max ].min
        (lo..hi).each do |j|
          v = [ prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + (ca == b[j - 1] ? 0 : 1) ].min
          curr[j] = v
          row_min = v if v < row_min
        end
        return nil if row_min > max

        prev = curr
      end
      prev.last <= max ? prev.last : nil
    end
  end
end
