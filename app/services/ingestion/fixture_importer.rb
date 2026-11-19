module Ingestion
  # Imports hand-written SERP fixtures. When a manifest.yml is present it
  # defines order and metadata; otherwise every *.html file is imported
  # alphabetically.
  class FixtureImporter
    def self.call(**) = new(**).call

    def initialize(dir:, engine: nil, query: "fixture")
      @dir = Pathname(dir)
      @engine = engine || @dir.basename.to_s
      @query = query
    end

    def call
      entries.map do |entry|
        path = @dir.join(entry.fetch("file"))
        SnapshotCreator.call(
          html: File.binread(path).force_encoding(Encoding::UTF_8),
          engine: @engine,
          source: "fixture",
          source_ref: entry.fetch("file"),
          query: entry["query"] || @query,
          locale: entry["locale"] || "en-US",
          device: entry["device"] || "desktop"
        )
      end
    end

    private

    def entries
      manifest = @dir.join("manifest.yml")
      if manifest.exist?
        YAML.safe_load_file(manifest).fetch("fixtures")
      else
        @dir.glob("*.html").sort.map { |p| { "file" => p.basename.to_s } }
      end
    end
  end
end
