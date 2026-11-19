module Healing
  # Proposes CSS selectors that reach `node` from inside `root` (a container,
  # or the scope for container healing). Each candidate carries a base
  # stability: how likely the selector survives the next layout change.
  #
  #   id (non-random)                     0.9
  #   [role=..] / [aria-level=..]          0.9
  #   semantic tag (h3, cite, a[href]...)  0.8
  #   [data-*] presence                    0.7
  #   tag.class (readable class)           0.7
  #   tag.class (obfuscated class)         0.5
  #   other attribute presence (jsname)    0.5
  #   generic tag (div, span)              0.4
  #   nth-of-type path                     0.3
  #   chains: min of parts
  class SelectorGenerator
    Candidate = Data.define(:selector, :kind, :stability)

    SEMANTIC = %w[h1 h2 h3 h4 h5 h6 a cite time img li article section header footer nav button label table].freeze
    SAFE_IDENT = /\A-?[A-Za-z_][\w-]*\z/
    RANDOM_ID = /\d{4,}|[A-Za-z0-9]{12,}/
    # Short mixed-case or digit-bearing class names ("yuRUbf", "tF2Cxc") are build-generated.
    OBFUSCATED = /\A(?=[A-Za-z0-9_-]{4,8}\z)(?:(?=.*[A-Z])(?=.*[a-z])|(?=.*\d)).*\z/
    STABLE_ATTRS = %w[role aria-level].freeze
    MAX_STEP_OPTIONS = 8

    def self.call(node, root:) = new(node, root).call

    def self.obfuscated?(name) = OBFUSCATED.match?(name)

    def initialize(node, root)
      @node = node
      @root = root
    end

    def call
      own = step_options(@node)
      out = own.dup
      parent, grand = ancestors_within_root.first(2)

      if parent
        step_options(parent).each { |p| own.each { |o| out << chain(p, o, " > ") } }
      end
      if grand
        step_options(grand).first(3).each { |g| own.first(3).each { |o| out << chain(g, o, " ") } }
      end
      out << nth_path if nth_path
      out.uniq(&:selector)
    end

    private

    def ancestors_within_root
      @node.ancestors.take_while { |a| a != @root && a.element? }
    end

    def step_options(node)
      tag = node.name
      options = []

      id = node["id"]
      options << Candidate.new("##{id}", "id", 0.9) if id && SAFE_IDENT.match?(id) && !RANDOM_ID.match?(id)

      STABLE_ATTRS.each do |attr|
        value = node[attr]
        options << Candidate.new(%(#{tag}[#{attr}="#{value}"]), "attr", 0.9) if value.present? && value.match?(/\A[\w-]{1,30}\z/)
      end

      node.attribute_nodes.map(&:name).select { |n| n.start_with?("data-") && SAFE_IDENT.match?(n) }.first(2).each do |attr|
        options << Candidate.new("#{tag}[#{attr}]", "attr", 0.7)
      end

      options << tag_candidate(node)

      classes = node.classes.uniq.select { |c| SAFE_IDENT.match?(c) }
      classes.each do |c|
        options << Candidate.new("#{tag}.#{c}", "class", self.class.obfuscated?(c) ? 0.5 : 0.7)
      end
      classes.first(3).combination(2).each do |pair|
        stab = pair.all? { |c| self.class.obfuscated?(c) } ? 0.5 : 0.7
        options << Candidate.new("#{tag}.#{pair.join('.')}", "class", stab)
      end

      (node.attribute_nodes.map(&:name) - %w[id class href style] - STABLE_ATTRS)
        .reject { |n| n.start_with?("data-") }.select { |n| SAFE_IDENT.match?(n) }.first(1).each do |attr|
          options << Candidate.new("#{tag}[#{attr}]", "attr", 0.5)
        end

      options.uniq(&:selector).sort_by { |c| -c.stability }.first(MAX_STEP_OPTIONS)
    end

    def tag_candidate(node)
      tag = node.name
      return Candidate.new("a[href]", "tag", 0.8) if tag == "a" && node["href"]
      return Candidate.new(tag, "tag", 0.8) if SEMANTIC.include?(tag)

      Candidate.new(tag, "tag", 0.4)
    end

    def chain(outer, inner, combinator)
      Candidate.new("#{outer.selector}#{combinator}#{inner.selector}", "chain", [ outer.stability, inner.stability ].min)
    end

    def nth_path
      @nth_path ||= begin
        steps = ([ @node ] + ancestors_within_root).reverse.map do |n|
          index = n.parent.element_children.select { |s| s.name == n.name }.index(n) + 1
          "#{n.name}:nth-of-type(#{index})"
        end
        steps.size > 1 ? Candidate.new(steps.join(" > "), "nth", 0.3) : nil
      end
    end
  end
end
