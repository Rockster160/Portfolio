# A recording's text file, turned into a conversation.
#
# What comes out of a meeting recorder is not a conversation, it is a list of
# captions: 1,214 of them for a half-hour call, most of them a few words long,
# each with its own timestamp and a speaker label the machine guessed at. Read
# straight it is unreadable, and there is nothing in it to point at.
#
# So the captions are gathered into TURNS - one per stretch of somebody
# talking - which is the unit a person reads, quotes and corrects.
#
# TWO FORMATS, because the exporters disagree. Most write cues with a
# `00:00:01 --> 00:00:04` line above the words; some write nothing but
# `Name: what they said`. The second is the fallback and it is recognised by
# there being no arrow anywhere in the file, not by a flag - nobody knows which
# exporter made the file they are dropping in.
class TranscriptParser
  # A silence longer than this starts a new turn even under the same label.
  # Only ten of the gaps in a thirty-minute call are this long, so it does
  # almost nothing to a tidy transcript and rescues a messy one, where a label
  # can sit unchanged across a handover.
  GAP = 2.0

  # `Speaker 1:`, `Unknown:`, `Casey Holm:`, `Dante McL.:`. The colon alone is
  # not enough to go on - `There was one thing: it never worked.` has one, and
  # read as a label it invents a speaker per sentence. So a candidate is taken
  # apart and it has to look like a NAME: at most three words, every one of
  # them starting with a capital or a digit.
  CANDIDATE = /\A([^:]{1,32}):[ \t]*(.*)\z/m
  WORD = /\A[A-Z0-9][\w'-]*\z/
  MOST_WORDS = 3

  CUE = /\A\s*(\d{1,2}:\d{2}(?::\d{2})?(?:[.,]\d+)?)\s*-->\s*(\d{1,2}:\d{2}(?::\d{2})?(?:[.,]\d+)?)/

  # What the recorder calls a voice it could not place. Worth naming because it
  # is the one label that is NOT a person: two different people both land under
  # it, so turns carrying it are the ones most worth correcting by hand.
  UNKNOWN = "Unknown".freeze

  def self.call(text) = new(text).turns

  def initialize(text)
    @text = text.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
  end

  def turns
    gathered = []
    captions.each do |caption|
      last = gathered.last
      if last && continues?(last, caption)
        last["to"] = caption[:to]
        last["text"] = join(last["text"], caption[:text])
      else
        gathered << turn_from(caption)
      end
    end
    gathered.reject { |turn| turn["text"].empty? }
  end

  # Every distinct label in the file, in the order they first speak. The
  # labelling form is built from this, so the order is the order of the
  # conversation rather than the alphabet.
  def self.speakers_in(turns)
    Array(turns).map { |turn| turn["raw"].to_s }.reject(&:empty?).uniq
  end

  private

  def captions
    lines = @text.gsub("\r\n", "\n").split("\n")
    return plain(lines) unless lines.any? { |line| line.match?(CUE) }

    cued(lines)
  end

  # A cue is its timestamp line plus everything up to the next blank line or
  # the next cue. The caption number some exporters write above the timestamp
  # is skipped by never looking above it.
  def cued(lines)
    found = []
    lines.each_with_index do |line, index|
      stamps = line.match(CUE)
      next if stamps.nil?

      said = []
      lines[(index + 1)..].to_a.each do |following|
        break if following.strip.empty? || following.match?(CUE)

        said << following.strip
      end
      next if said.empty?

      label, text = split_label(said.join(" "))
      found << { at: seconds(stamps[1]), to: seconds(stamps[2]), label: label, text: text }
    end
    found
  end

  # No timestamps anywhere, so the only structure is the label at the front of
  # each line. A line without one continues the line above it, which is how a
  # paragraph that wrapped survives.
  def plain(lines)
    found = []
    lines.each do |line|
      said = line.strip
      next if said.empty?

      label, text = split_label(said)
      if label.nil? && found.any?
        found.last[:text] = join(found.last[:text], text)
        next
      end
      found << { at: nil, to: nil, label: label, text: text }
    end
    found
  end

  def split_label(said)
    found = said.match(CANDIDATE)
    return [nil, said.strip] unless found && label?(found[1])

    [found[1].strip, found[2].strip]
  end

  def label?(candidate)
    words = candidate.to_s.split(/[ .]+/).reject(&:empty?)
    return false if words.empty? || words.size > MOST_WORDS

    words.all? { |word| word.match?(WORD) }
  end

  def continues?(turn, caption)
    return false unless turn["raw"] == (caption[:label] || UNKNOWN)
    return true if turn["to"].nil? || caption[:at].nil?

    caption[:at] - turn["to"] <= GAP
  end

  def turn_from(caption)
    label = caption[:label] || UNKNOWN
    # `raw` is what the machine said and never changes; `speaker` is who it
    # turned out to be. Keeping both is what lets a label be relabelled in
    # bulk while a turn corrected by hand stays corrected.
    {
      "raw"     => label,
      "speaker" => label,
      "at"      => caption[:at],
      "to"      => caption[:to],
      "text"    => caption[:text].to_s.strip,
    }
  end

  # The captions are sentence fragments - `Well,` then `thanks so much for
  # joining us today.` - so they join with a space and not a newline. The
  # squeeze is because a good few of them arrive already padded.
  def join(said, more)
    [said, more].reject { |part| part.to_s.strip.empty? }.join(" ").squeeze(" ").strip
  end

  def seconds(stamp)
    parts = stamp.to_s.tr(",", ".").split(":").map(&:to_f)
    parts.unshift(0.0) while parts.size < 3
    (parts[0] * 3600) + (parts[1] * 60) + parts[2]
  end
end
