# == Schema Information
#
# Table name: job_transcripts
#
#  id                 :bigint           not null, primary key
#  occurred_at        :datetime
#  speakers           :jsonb            not null
#  title              :string
#  turns              :jsonb            not null
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  job_application_id :bigint           not null
#  job_note_id        :bigint
#
class JobTranscript < ApplicationRecord
  belongs_to :job_application
  belongs_to :job_note, optional: true

  # The file as it was dropped in, kept whatever happens to the parse. The
  # turns below are a reading of it and they are edited by hand; the upload is
  # the thing that can be read again if the reading was wrong.
  has_one_attached :file

  validates :turns, presence: true

  scope :ordered, -> { order(Arel.sql("COALESCE(occurred_at, created_at) DESC")) }

  # What a recorder calls a voice it could not place. Two different people land
  # under it, so it is the one label that must never be treated as a person -
  # `mine?` refuses it even if it somehow got ticked.
  UNKNOWN = TranscriptParser::UNKNOWN

  # Read the file, work out the conversation, and leave the speakers blank for
  # him to name. Nothing guesses who anybody is: the recorder's own guess is
  # `Speaker 2`, and a wrong name on a quote he later reads back is worse than
  # no name at all.
  def ingest!(io, filename: nil)
    text = io.respond_to?(:read) ? io.read : io.to_s
    self.turns = TranscriptParser.call(text)
    self.title = title.presence || File.basename(filename.to_s, ".*").tr("-_", " ").strip.presence
    self.occurred_at ||= job_note&.occurred_at
    self
  end

  # Everybody speaking, in the order they first speak - which is the order the
  # conversation introduces them, and so the order they are easiest to name.
  #
  # Read off `speaker` rather than `raw`, because that is who the turn is ON:
  # a split into sides writes `Me` and `Them` there while `raw` stays the
  # nothing the file said, and a naming form built off `raw` would offer him a
  # row for a label no turn is on any more.
  def labels
    @labels ||= turns.map { |turn| turn["speaker"].presence || turn["raw"].to_s }.compact_blank.uniq
  end

  # Did the file name anybody at all? One label for the whole conversation is
  # the same thing as none: a recorder that heard one voice, or a phone
  # transcription that is half an hour of unbroken text.
  def unlabelled?
    TranscriptParser.speakers_in(turns).size <= 1
  end

  # The pass, while it is on this transcript - the same chip the worker raises,
  # found by the same key. A row here is the one honest answer to "is it
  # actually doing something": the alternative is a column on this table that
  # says a pass started and goes on saying it after the worker that set it
  # died.
  def reading
    @reading ||= BackgroundProcess.live_find(job_application.user, Transcripts::Speakers.key_for(self))
  end

  def reading?
    reading.present?
  end

  # The labels a turn can be moved to. The same list, plus whatever a turn has
  # already been corrected to, so a correction is never the one option missing.
  def speaker_options
    (labels + turns.map { |turn| turn["speaker"].to_s }).reject(&:empty?).uniq
  end

  def name_for(label)
    speakers.dig(label.to_s, "name").presence || label.to_s
  end

  def mine?(label)
    return false if label.to_s == UNKNOWN

    speakers.dig(label.to_s, "me").present?
  end

  # A line of theirs, to tell two unnamed labels apart in the naming form. The
  # first thing somebody says is nearly always the introduction.
  def first_words(label, limit: 90)
    said = turns.find { |turn| turn["speaker"].to_s == label.to_s }
    said.to_h["text"].to_s.truncate(limit)
  end

  def turn_count(label)
    turns.count { |turn| turn["speaker"].to_s == label.to_s }
  end

  # `{ "Speaker 2" => { "name" => "Rocco", "me" => "1" } }` off the form.
  def rename_speakers!(given)
    named = given.to_h.each_with_object({}) { |(label, fields), found|
      name = fields.to_h["name"].to_s.strip
      me = fields.to_h["me"].to_s.present? && fields.to_h["me"].to_s != "0"
      next if name.empty? && !me

      found[label.to_s] = { "name" => name, "me" => me }
    }
    update!(speakers: named)
  end

  # `{ "12" => "Speaker 3" }` - the turns whose speaker he corrected. Only the
  # ones that actually moved are written, so a submit of the whole page does
  # not rewrite 126 rows to say what they already said.
  def reassign!(given)
    moved = turns.dup
    changed = 0
    given.to_h.each do |index, label|
      at = index.to_i
      said = label.to_s
      next if moved[at].nil? || said.empty? || moved[at]["speaker"].to_s == said

      moved[at] = moved[at].merge("speaker" => said)
      changed += 1
    end
    update!(turns: moved) if changed.positive?
    changed
  end

  def spoken_minutes
    first = turns.first.to_h["at"]
    last = turns.last.to_h["to"]
    return nil if first.nil? || last.nil?

    ((last - first) / 60).round
  end

  def label
    title.presence || "Transcript"
  end
end
