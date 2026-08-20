require "rails_helper"

# A sample reply in a persona file gets used.
#
# That is the whole point of most of them - `Mooooorning!`, `Ag shame!`,
# `Thank youuuu!` are there to be borrowed, and borrowing them is how a
# companion sounds like itself. None of those carry a fact, so a verbatim echo
# costs nothing.
#
# A sample that carries a VALUE is a different object wearing the same clothes.
# "up in about twenty minutes" and "on your calendar for noon" read as
# illustrations to whoever wrote them and as sentences to the model, and when
# one gets borrowed the number comes with it - a claim about the person's day
# that nothing anywhere checked. Buddy::TodayBriefing::TONE carries the same
# rule for the briefing seed, and the reason it is written down: two agenda
# items put in that prompt purely as what-NOT-to-say illustrations were both
# read out by name on the days they came round.
#
# Scoped to the companion's own files. `tone_profiles/` describes how the PERSON
# writes, so a time in one of those is a quote of them rather than a reply
# waiting to be sent.
RSpec.describe "persona sample replies" do
  persona_files = Rails.root.glob("app/service/buddy/personalities/*.md")

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

  persona_files.each do |path|
    name = path.basename.to_s

    describe name do
      fabricated.each do |label, pattern|
        it "hands the model no sample carrying #{label}" do
          caught = samples_in(path).grep(pattern)

          expect(caught).to be_empty,
            "#{name} offers #{label} inside a sample the model can send verbatim: " \
            "#{caught.inspect}. Describe the shape instead, and say the figure comes " \
            "from the record."
        end
      end
    end
  end

  it "covers every companion, so a new one cannot skip the check" do
    checked = persona_files.map { |p| p.basename(".md").to_s }

    expect(checked).to match_array(Buddy::Themes.keys.map(&:to_s))
  end
end
