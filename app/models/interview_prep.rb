# == Schema Information
#
# Table name: interview_preps
#
#  id                 :bigint           not null, primary key
#  body               :text
#  interview_at       :datetime
#  kind               :string
#  title              :string
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  agenda_item_id     :bigint
#  byte_message_id    :bigint
#  job_application_id :bigint           not null
#
class InterviewPrep < ApplicationRecord
  belongs_to :job_application
  # The booking it was written for. Optional: a brief asked for by hand has no
  # calendar row behind it, and the row can be deleted after the fact.
  belongs_to :agenda_item, optional: true
  # Where the research happened, for reading back when the brief says something
  # wrong. Optional because the thread gets swept and the brief outlives it.
  belongs_to :byte_message, optional: true

  validates :body, presence: true

  scope :ordered, -> { order(Arel.sql("COALESCE(interview_at, created_at) DESC")) }
  scope :upcoming, -> { where(interview_at: Time.current..) }

  # What the session decided it was writing for, and what to call that on the
  # page. Anything it answers that isn't on this list is kept as it said it and
  # titled by `kind_label` falling through - a brief for something nobody
  # anticipated should not be relabelled into one of these.
  KIND_LABELS = {
    "recruiter"  => "Recruiter call",
    "technical"  => "Technical interview",
    "behavioral" => "Behavioral interview",
    "panel"      => "Panel interview",
    "onsite"     => "Onsite",
    "manager"    => "Hiring manager interview",
  }.freeze

  KINDS = KIND_LABELS.keys.freeze

  # The opening lines the session is asked for, and the only two things read out
  # of the report rather than left in it. Both optional on purpose: a brief that
  # forgot its heading is still the brief, and a missing kind reads as "a brief"
  # rather than being guessed at from the prose.
  # ONE hash, not two. `#\s*` happily matches `## The company`, which is the
  # first SECTION of every brief - so an otherwise perfect report had its first
  # section heading lifted out and used as the page title.
  TITLE_LINE = /\A\s*\#(?!\#)\s*(?<title>.+?)\s*\z/
  KIND_LINE = /\A\s*(?:\*\*)?KIND(?:\*\*)?\s*:\s*(?<kind>[a-z_ -]+?)\s*\z/i

  # How far in the report to look for them. They are asked for as the first two
  # lines; a handful of slack covers a blank line or a stray preamble, and
  # anything past that is prose that happens to start with a hash.
  OPENING_LINES = 6

  # Build one out of what a session wrote. The title and kind come off the top
  # of the report and the rest is kept verbatim - this is HIS brief, and a
  # reformat here would be a second opinion on something already written to be
  # read in five minutes.
  def self.from_report(report, **attrs)
    lines = report.to_s.lines
    head = lines.first(OPENING_LINES)
    title = head.filter_map { |line| line[TITLE_LINE, :title] }.first
    kind = head.filter_map { |line| line[KIND_LINE, :kind] }.first

    new(attrs.merge(title: title, kind: normalize_kind(kind), body: strip_opening(lines).strip))
  end

  # Drops the two lines that became columns, and the blank line left behind
  # them. Matched against the same window rather than the whole report, so a
  # `# heading` three sections down stays a heading.
  def self.strip_opening(lines)
    kept = lines.each_with_index.reject { |line, index|
      index < OPENING_LINES && (line.match?(TITLE_LINE) || line.match?(KIND_LINE))
    }
    kept.map(&:first).join.sub(/\A\s*\n+/, "")
  end

  def self.normalize_kind(said)
    found = said.to_s.strip.downcase.tr(" -", "__").presence
    found if found && found != "unknown"
  end

  # The heading on the page and the link text everywhere else. The kind first,
  # because what the conversation IS is the thing that decides whether the
  # brief is worth opening right now.
  def label
    [kind_label, job_application.company].compact_blank.join(" - ")
  end

  def kind_label
    return nil if kind.blank?

    KIND_LABELS[kind] || kind.tr("_", " ").capitalize
  end

  # Its own page. Written into the message Byte pushes, which is the whole
  # point of the record having one.
  def prep_url
    Rails.application.routes.url_helpers.interview_prep_url(job_application, self)
  end

  # Was it written for an interview that has already happened? A brief is read
  # once, in the hour before; afterwards it is reference, and the page says so
  # rather than pretending to be urgent.
  def spent?
    interview_at.present? && interview_at.past?
  end

  # Still ahead of him, which is the one state worth opening a section for.
  # A brief with no time on it is neither: it was asked for by hand and nothing
  # is counting down to it.
  def upcoming?
    interview_at.present? && interview_at.future?
  end
end
