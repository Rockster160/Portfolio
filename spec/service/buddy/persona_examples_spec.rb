require "rails_helper"

# A sample reply in a persona file gets borrowed verbatim. Tone samples carry
# no fact and cost nothing; a sample carrying a VALUE (a time, a duration, a
# tally) brings an unchecked claim about the person's day along with it.
#
# Scoped to the companion's own files. `tone_profiles/` describes how the PERSON
# writes, so a time in one of those is a quote of them rather than a reply
# waiting to be sent.
RSpec.describe "persona sample replies" do
  persona_files = Rails.root.glob("app/service/buddy/companions/*/persona.md")

  # Shapes that only ever appear as a made-up quantity. A number the person
  # themselves said is fine and common ("set a timer for 10", "remind me to
  # fetch Ryker at 3"), so a bare digit is deliberately not one of these.
  fabricated = {
    "a clock time"       => /\b\d{1,2}:\d{2}\s*(?:[ap]\.?m\.?)?/i,
    "a spelled-out hour" => /\b(?:half|quarter)\s+(?:past\s+)?(?:one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)\b/i,
    "a made-up duration" => /\b(?:about|in|for|another)\s+(?:a\s+couple\s+of|a\s+few|\w+teen|twenty|thirty|forty|fifty|ten|five)\s+(?:more\s+)?(?:minutes|hours|days|weeks|months)\b/i,
    "an invented tally"  => /\b(?:second|third|fourth|fifth|sixth)\s+\w+\s+this\s+(?:week|month)\b/i,
    "an invented streak" => /\bevery\s+day\s+for\s+\w+\s+days\b/i,
  }

  # Backticked and double-quoted runs long enough to be a sentence rather than a
  # single word of vocabulary.
  def samples_in(path)
    File.read(path).scan(/`([^`\n]{12,})`|"([^"\n]{12,})"/).flatten.compact
  end

  it "hands the model no sample reply carrying a made-up value, in any companion's persona", :aggregate_failures do
    expect(persona_files.map { |p| p.dirname.basename.to_s }).to match_array(Buddy::Themes.keys.map(&:to_s))

    persona_files.each do |path|
      name = path.dirname.basename.to_s
      fabricated.each do |label, pattern|
        caught = samples_in(path).grep(pattern)

        expect(caught).to be_empty,
          "#{name} offers #{label} inside a sample the model can send verbatim: " \
          "#{caught.inspect}. Describe the shape instead, and say the figure comes " \
          "from the record."
      end
    end
  end
end
