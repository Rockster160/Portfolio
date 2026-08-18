module Buddy
  # "If she says yes." A condition an ASKING step carries, answered against what
  # came back rather than against the world.
  #
  # ScheduleCondition is the other condition in the app and the two don't
  # overlap: that one asks whether something is true out there — a search, a Jil
  # task — at the moment a reminder fires. This one asks what a PERSON said,
  # which is not a fact about anything else and is not knowable until they've
  # said it.
  #
  # Without it, everything queued behind a question ran on ANY answer, because
  # it was all decided before the answer existed. "Ask Chelsea if she wants
  # syrup for dinner; if she says yes, add it to the agenda" booked the dinner
  # whether she wanted it or not, and the "if" was decorative in exactly the way
  # a reminder's used to be.
  #
  # THREE outcomes, not two. An answer that doesn't clearly go either way —
  # "maybe", "I'll think about it" — is its own case. Acting on it is the bug
  # this exists to stop; dropping it in silence is the other one. So it stops
  # and says why, and the person can ask again.
  module AnswerCondition
    module_function

    # Words that are the whole answer. Checked against the FRONT of what they
    # said, so "no thanks" and "not really" are read off their first word rather
    # than by hunting for a "no" somewhere in a sentence.
    NO_LEAD  = /\A(?:n|no|nope|nah|naw|not|never|dont|don't|do not|pass|skip|rather not|i'd rather not)\b/
    YES_LEAD = /\A(?:y|ya|yes|yep|yeah|yup|sure|ok|okay|kk|please|definitely|absolutely|of course|sounds good|go for it|go ahead|do it|i do|i would)\b/

    # The looser pass, for an answer that says it somewhere other than the
    # front: "I'd love that, yes". Only counts when just ONE of the two shows
    # up — "yes to the pasta, no to the syrup" is not an answer to this
    # question and must not be read as one.
    YES_WORD = /\b(?:yes|yeah|yep|yup|sure|please do|sounds good|go ahead)\b/
    NO_WORD  = /\b(?:no|nope|nah|dont|don't|do not|not really|rather not|never)\b/

    # What counts as asking for a plain yes or no, rather than for a particular
    # answer by name.
    POLARITIES = {
      "yes"         => :yes,
      "y"           => :yes,
      "yeah"        => :yes,
      "yep"         => :yes,
      "true"        => :yes,
      "affirmative" => :yes,
      "no"          => :no,
      "n"           => :no,
      "nope"        => :no,
      "false"       => :no,
      "negative"    => :no,
    }.freeze

    # What a condition looks like on the gate: which captured value to read,
    # what it has to say, and whose answer it is — the last only so the line
    # that reports a stop can name them. Nil when there's nothing to check,
    # which is every gate that came before this existed.
    def build(var:, is:, who: nil)
      name = var.to_s.strip
      want = is.to_s.strip
      return nil if name.empty? || want.empty?

      { "var" => name, "is" => want, "who" => who.to_s.strip.presence }.compact
    end

    # :met, :unmet or :unclear. A blank condition is :met — the overwhelming
    # majority of sequences don't have one, and they must keep running.
    def check(condition, vars)
      return :met if condition.blank?

      said = answers(condition, vars)
      return :unclear if said.empty?

      want = condition["is"].to_s
      return polarity_check(said, want) if POLARITIES.key?(want.downcase)

      said.any? { |one| names?(one, want) } ? :met : :unmet
    end

    # The clause that goes in front of ", so I didn't go on to <the rest>".
    def describe(condition, vars, outcome)
      who  = condition["who"].presence || "You"
      want = condition["is"].to_s
      said = answers(condition, vars).join(", ")

      if outcome == :unclear
        return "#{who} never answered that" if said.empty?

        return "#{who} said \"#{said}\", and I couldn't tell whether that was a #{want}"
      end

      case POLARITIES[want.downcase]
      when :yes then "#{who} said no"
      when :no  then "#{who} said yes"
      else "#{who} said \"#{said}\", not #{want}"
      end
    end

    def answers(condition, vars)
      Array.wrap((vars || {})[condition["var"].to_s]).map(&:to_s).compact_blank
    end

    # Every part of a multi-answer has to agree. "Yes to one, no to the other"
    # is not a yes, and it isn't a no either.
    def polarity_check(said, want)
      read = said.map { |one| polarity(one) }.uniq
      return :unclear if read.include?(:unclear) || read.size > 1

      read.first == POLARITIES[want.downcase] ? :met : :unmet
    end

    def polarity(text)
      raw   = text.to_s.strip
      words = normalize(raw)
      return emoji(raw) if words.empty?

      yes = words.match?(YES_WORD)
      no  = words.match?(NO_WORD)
      # BOTH, in one answer. "Yes to the pasta, no to the syrup" is not an
      # answer to the question that was asked, and which of the two happens to
      # come first says nothing about which one this was. Checked before the
      # leading word, because reading it off the front is exactly what would
      # call that a yes.
      return :unclear if yes && no
      # NO first: "no thanks" and "not really" open with words the yes list
      # would otherwise walk straight past.
      return :no  if words.match?(NO_LEAD)
      return :yes if words.match?(YES_LEAD)
      return :yes if yes
      return :no  if no

      emoji(raw)
    end

    # A thumb is a whole answer on its own, and often the only one a person
    # sends. Read last, so it can't overturn words that already said something.
    def emoji(raw)
      up   = raw.match?(/[👍✅✔]/)
      down = raw.match?(/[👎❌✖]/)
      return :yes if up && !down
      return :no  if down && !up

      :unclear
    end

    # Their answer NAMES the thing the condition asked for. Whole words only, so
    # "no pizza" can't satisfy `is: "pizza"` by containing it.
    def names?(answer, want)
      one  = normalize(answer)
      this = normalize(want)
      return false if this.empty? || one.empty?

      one == this || one.match?(/\b#{Regexp.escape(this)}\b/)
    end

    # Punctuation out, apostrophes kept — "don't" has to survive to be read.
    def normalize(text)
      text.to_s.downcase.tr("’", "'").gsub(/[^a-z0-9'\s]/, " ").squish
    end
  end
end
