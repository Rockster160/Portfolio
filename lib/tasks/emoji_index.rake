require "json"
require "open-uri"

namespace :emoji do
  desc "Rebuild public/emoji_index.json from the upstream gemoji dataset"
  task rebuild_index: :environment do
    src = ENV["EMOJI_SRC"] || "https://raw.githubusercontent.com/github/gemoji/master/db/emoji.json"
    out = Rails.public_path.join("emoji_index.json")
    extras = load_search_aliases.fetch("emoji", {})

    raw = src.start_with?("http") ? URI.parse(src).open(&:read) : File.read(src)
    data = JSON.parse(raw)

    index = data.map { |e|
      char    = e["emoji"]
      aliases = Array(e["aliases"])
      tags    = Array(e["tags"])
      desc    = e["description"].to_s
      extra   = Array(extras[char])
      # Curated extras come FIRST so positional scoring treats them as
      # the most authoritative aliases. The iconic flower emoji get
      # "flower" at index 0; novelty rows like 🎴 only get it via the
      # description split, which lands further down.
      words   = extra + aliases.flat_map { |a| a.split("_") } + tags + desc.split(/\W+/)
      keywords = expand_inflections(words)

      {
        "c" => char,
        "n" => desc,
        "k" => keywords,
      }
    }.reject { |row| row["c"].to_s.empty? }

    File.write(out, JSON.generate(index))
    puts "Wrote #{index.size} emoji entries → #{out} (#{File.size(out)} bytes)"
  end
end

# Hand-curated search aliases. Lives at db/icon_search_aliases.json
# with two top-level keys (`emoji`, `ti`) so both rake tasks pull
# from the same file. Returns {} on missing/parse error so a typo
# never blocks an index rebuild.
def load_search_aliases
  path = Rails.root.join("db/icon_search_aliases.json")
  return {} unless File.exist?(path)

  JSON.parse(File.read(path))
rescue JSON::ParserError => e
  warn "[icon_search_aliases] parse error: #{e.message}"
  {}
end

# Expand keyword list with both singular and plural forms so search
# matches across "tooth" ↔ "teeth", "knife" ↔ "knives", regular
# plurals like "brush" ↔ "brushes", etc. Uses ActiveSupport's
# inflector — handles irregulars and standard English rules.
def expand_inflections(words)
  expanded = []
  seen = Set.new
  words.each do |w|
    next if w.nil?

    base = w.to_s.downcase.strip
    next if base.empty?

    [base, base.singularize, base.pluralize].each { |form|
      next if form.empty? || seen.include?(form)

      seen << form
      expanded << form
    }
  end
  expanded
end
