require "json"
require "open-uri"
require "tempfile"

namespace :lorcana do
  desc "Refresh lorcana_keywords.json from the official Disney Lorcana Comprehensive Rules PDF. Requires pdftotext (brew install poppler)."
  task :update_glossary, [:url] => :environment do |_t, args|
    url = args[:url] || "https://files.disneylorcana.com/Disney-Lorcana-Comprehensive-Rules-020526-EN-Edited.pdf"
    abort "pdftotext not found. Install with: brew install poppler" unless system("which pdftotext > /dev/null 2>&1")

    puts "Fetching rules PDF from #{url}"
    pdf_data = URI.parse(url).read

    Tempfile.create(["lorcana_rules", ".pdf"]) do |pdf_file|
      pdf_file.binmode
      pdf_file.write(pdf_data)
      pdf_file.flush

      Tempfile.create(["lorcana_rules", ".txt"]) do |txt_file|
        system("pdftotext", "-layout", pdf_file.path, txt_file.path) || abort("pdftotext failed")
        txt = File.read(txt_file.path, encoding: "UTF-8")
        entries = parse_lorcana(txt)
        out = Rails.root.join("lorcana_keywords.json")
        File.write(out, JSON.pretty_generate(entries))
        kw = entries.count { |e| e[:category] == "Keyword" }
        gloss = entries.count { |e| e[:category] == "Glossary Term" }
        puts "Wrote #{entries.length} entries (#{kw} keywords + #{gloss} glossary terms) to #{out}"
      end
    end
  end

  def parse_lorcana(txt)
    lines = txt.split(/\r?\n/)
    keywords = parse_keywords(lines)
    glossary = parse_glossary(lines)
    keywords + glossary
  end

  def footer?(line)
    s = line.strip
    s.empty? || s == "disneylorcana.com" || s.start_with?("©Disney") || s.match?(/\A\d+\z/)
  end

  def strip_subnum_prefix(line)
    line.sub(/\A\s*8\.\d+(?:\.\d+)*\.\s*/, "").strip
  end

  def parse_keywords(lines)
    keywords = []
    in_section = false
    current = nil
    heading_re = /\A\s*8\.(\d+)\.\s+([A-Z][A-Za-z][A-Za-z0-9 \-]+?)\s*\z/
    subheading_with_text_re = /\A\s*8\.\d+(?:\.\d+)*\.\s+/

    lines.each do |line|
      if line.strip == "8. KEYWORDS"
        in_section = true
        next
      end
      next unless in_section
      break if line.strip == "9. MULTIPLAYER" || line.strip.start_with?("9.")
      next if footer?(line)

      if (m = heading_re.match(line))
        keywords << current if current && current[:num] != "1"
        current = { section: "8", num: m[1], name: m[2].strip, category: "Keyword", body: [] }
      elsif current
        cleaned = strip_subnum_prefix(line)
        if line.match?(subheading_with_text_re)
          current[:body] << cleaned unless cleaned.empty?
        elsif current[:body].any?
          current[:body][-1] = "#{current[:body][-1]} #{cleaned}".strip
        elsif !cleaned.empty?
          current[:body] << cleaned
        end
      end
    end
    keywords << current if current && current[:num] != "1"
    keywords.reject! { |k| k[:num] == "1" }
    keywords.each do |k|
      k[:definition] = k[:body].join("\n\n")
      k.delete(:body)
    end
    keywords
  end

  # A term in the glossary section is a short line that doesn't end with sentence
  # punctuation, doesn't start with common definition-opening words, and follows the
  # end of a previous definition. Lines between terms are accumulated as one paragraph.
  def term_like?(line)
    s = line.strip
    return false if s.empty?
    return false if s.length > 70
    return false if s =~ /[\.\?\!]\z/
    return false if s =~ /\A(A|An|The|When|Whenever|If|During|Each|While|This|These|That|Some|Any|Special|How|Once|Players|All|One|To|For)\s/
    return false if s.split(/\s+/).length > 6
    true
  end

  def parse_glossary(lines)
    start = lines.index { |l| l.strip == "GLOSSARY" }
    return [] unless start

    gloss_lines = lines[(start + 1)..].reject { |l| footer?(l) }
    entries = []
    current = nil
    prev_ended_def = true

    gloss_lines.each do |line|
      s = line.strip
      next if s.empty?

      if term_like?(line) && prev_ended_def
        entries << current if current
        current = { section: "11", num: (entries.length + 1).to_s, name: s, category: "Glossary Term", body: [] }
        prev_ended_def = false
      elsif current
        if current[:body].any?
          current[:body][-1] = "#{current[:body][-1]} #{s}".strip
        else
          current[:body] << s
        end
        prev_ended_def = !!(s =~ /[\.\?\!]\z/)
      end
    end
    entries << current if current

    entries.each do |k|
      k[:definition] = k[:body].join(" ").strip
      k.delete(:body)
    end
    entries.reject! { |k| k[:definition].to_s.strip.empty? }
    entries
  end
end
