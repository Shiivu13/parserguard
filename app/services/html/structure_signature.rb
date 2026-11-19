module Html
  # Turns a DOM into two multisets of root-to-node paths, truncated to the last
  # `depth` ancestors:
  #   tag:   "div>div>a>h3"                      (pure structure)
  #   class: "div.g>div.yuRUbf>a>h3.LC20lb"     (structure + styling hooks)
  # Comparing these histograms between snapshots gives the drift score.
  class StructureSignature
    Signature = Data.define(:tag, :klass) do
      def to_h = { tag_histogram: tag, class_histogram: klass }
    end

    def self.call(doc, scope: "body", depth: nil) = new(doc, scope:, depth:).call

    def initialize(doc, scope: "body", depth: nil)
      @doc = doc
      @scope = scope.presence || "body"
      @depth = depth || Rails.application.config.parserguard.dig(:drift, :path_depth) || 6
    end

    def call
      @tag = Hash.new(0)
      @klass = Hash.new(0)
      root = @doc.at_css(@scope) || @doc
      walk(root, [], []) if root
      Signature.new(tag: pairs(@tag), klass: pairs(@klass))
    end

    def self.step(node)
      classes = node.classes.uniq.sort
      classes.empty? ? node.name : "#{node.name}.#{classes.join('.')}"
    end

    private

    def walk(node, tags, classes)
      node.element_children.each do |child|
        t = tags + [ child.name ]
        c = classes + [ self.class.step(child) ]
        @tag[t.last(@depth + 1).join(">")] += 1
        @klass[c.last(@depth + 1).join(">")] += 1
        walk(child, t.last(@depth), c.last(@depth))
      end
    end

    def pairs(hash) = hash.sort_by { |path, _| path }.map { |path, count| [ path, count ] }
  end
end
