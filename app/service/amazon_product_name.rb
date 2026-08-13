# Turns an Amazon product title into something that fits in a memo cell.
#
# Titles are written for search, not for reading: 139 characters at the median
# across 1,595 distinct ones here, 273 at the worst, most of it a feature list
# bolted onto the actual name. "NZQXJXZ 10X Magnifying Glass with Light, Clip on
# Mganifier with Light, 48 LED Desk Magnifying Glass wtih Clamp" is one product.
#
# What it does NOT do is strip the brand. Telling a real one from a coined one
# ("Rubbermaid" from "Hansleep", "BISSELL" from "AULIGET") cannot be done by
# shape — both are capitalised words with no other tell — and guessing wrong
# deletes the most identifying part of the name.
module AmazonProductName
  MAX = 55

  # The order matters: a bracketed aside comes off before the pack count behind
  # it can be seen. "(50 Pads) 160 Pcs Sticky Notes" needs both.
  LEADING_NOISE = [
    /\A[(\[][^)\]]{0,30}[)\]]\s*/,
    /\A\d+\s*[-x]?\s*(pcs?|pieces?|packs?|pads?|count|ct|sets?)\b[.,]?\s*/i,
    /\A(pack of|set of|lot of)\s+\d+\s*[-,]?\s*/i,
    /\A\d+\s*[-x]\s*/,
  ].freeze

  # Where a title stops naming the thing and starts listing its features.
  SPLIT = /,|;|\||\bwith\b|\bfor\b|\(|\[|\s[-–—:]\s/
  # Splitting on "with"/"for" can strand the qualifier: "Moko Charging Stand
  # Compatible" wants to lose that last word.
  DANGLING = /\s+(compatible|designed|suitable|ideal|perfect|great)\z/i
  TRAILING_PUNCTUATION = /[\s,\-–—:]+\z/

  class << self
    def tidy(name)
      text = strip_leading_noise(name.to_s.strip)
      head = text.split(SPLIT).first.to_s.squeeze(" ").strip
      head = head.sub(DANGLING, "")
      # A stub is worse than a long title — "Ajmal" alone says nothing, while
      # the full name at least says it is cologne. Two words is enough to be a
      # name, though: "Power Strip" must not be reverted for being short.
      head = text if head.split.size < 2 || head.length < 8

      truncate(head.sub(TRAILING_PUNCTUATION, ""))
    end

    # What one charge covered, when a shipment held several things.
    def summarize(names)
      cleaned = Array(names).map { |name| tidy(name) }.compact_blank
      return nil if cleaned.empty?
      return cleaned.first if cleaned.one?

      "#{cleaned.first} + #{cleaned.size - 1} more"
    end

    private

    def strip_leading_noise(text)
      loop do
        before = text
        LEADING_NOISE.each { |pattern| text = text.sub(pattern, "") }
        return text if text == before
      end
    end

    def truncate(head)
      return head if head.length <= MAX

      cut = head[0, MAX + 1]
      cut = cut[0, cut.rindex(" ") || MAX]
      "#{cut.sub(TRAILING_PUNCTUATION, "")}…"
    end
  end
end
