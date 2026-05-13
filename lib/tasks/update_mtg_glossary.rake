require "json"
require "open-uri"

namespace :mtg do
  desc "Refresh mtg_keywords.json from the official MTG Comprehensive Rules text file"
  task :update_glossary, [:url] => :environment do |_t, args|
    url = args[:url] || "https://media.wizards.com/2026/downloads/MagicCompRules%2020260227.txt"
    puts "Fetching rules from #{url}"
    rules = URI.parse(url).read
    rules = rules.force_encoding("UTF-8").sub(/\A\xEF\xBB\xBF/, "")

    keywords = []
    current = nil
    heading_re = /\A(70[12])\.(\d+)\. (.+?)\s*\z/

    rules.split(/\r?\n/).each do |line|
      if (m = heading_re.match(line))
        keywords << current if current
        section, num, name = m[1], m[2], m[3]
        if num.to_i == 1
          current = nil
        else
          current = {
            section: section,
            num: num,
            name: name.strip,
            body: [],
            category: (section == "701" ? "Keyword Action" : "Keyword Ability"),
          }
        end
      elsif current && !line.strip.empty?
        cleaned = line.sub(/\A70[12]\.\d+[a-z]+\s+/, "").strip
        current[:body] << cleaned unless cleaned.empty?
      end
    end
    keywords << current if current

    keywords.each do |kw|
      kw[:definition] = kw[:body].join("\n\n")
      kw.delete(:body)
    end

    out = Rails.root.join("mtg_keywords.json")
    File.write(out, JSON.pretty_generate(keywords))
    puts "Wrote #{keywords.length} keywords to #{out}"
  end
end
