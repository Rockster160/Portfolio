require "json"

namespace :icons do
  desc "Rebuild public/icons_index.json from icons.json — derives searchable keywords from the ti-* name"
  task rebuild_index: :environment do
    src = Rails.root.join("icons.json")
    out = Rails.public_path.join("icons_index.json")
    extras = load_search_aliases.fetch("ti", {})

    raw = JSON.parse(File.read(src))
    rows = (
      case raw
      when Array then raw.map { |name| [name, nil] }
      when Hash  then raw.to_a
      else raise "Unexpected icons.json shape: #{raw.class}"
      end
    )

    index = rows.map { |(name, extra)|
      bare = name.to_s.sub(/\Ati-/, "")
      words = bare.split(/[-_]/).reject(&:empty?)
      extra_words = Array(extra).flat_map { |t| t.to_s.split(/[-_\s]/) }
      curated = Array(extras[name.to_s])
      keywords = expand_inflections(extra_words + words + curated)
      display = bare.tr("_", " ").tr("-", " ").strip

      {
        "c" => name,
        "n" => display,
        "k" => keywords,
      }
    }

    File.write(out, JSON.generate(index))
    puts "Wrote #{index.size} icon entries → #{out} (#{File.size(out)} bytes)"
  end
end

# Expand keyword list with both singular and plural forms so search
# matches across "tooth" ↔ "teeth", "knife" ↔ "knives", etc. Uses
# ActiveSupport's inflector — handles irregulars and standard
# English rules.
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
