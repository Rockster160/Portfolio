# == Schema Information
#
# Table name: job_applications
#
#  id               :bigint           not null, primary key
#  color            :string           not null
#  company          :string           not null
#  last_activity_at :datetime
#  logo             :text
#  role             :string
#  source           :string
#  status           :integer          default("active"), not null
#  url              :string
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  jobhunt_job_id   :integer
#  user_id          :bigint           not null
#
class JobApplication < ApplicationRecord
  belongs_to :user
  has_many :notes, -> { ordered }, class_name: "JobNote", inverse_of: :job_application,
    dependent: :destroy
  has_many :transcripts, -> { ordered }, class_name: "JobTranscript", inverse_of: :job_application,
    dependent: :destroy
  # The briefs written for this one's interviews. Research rather than record:
  # they are read once in the hour before and kept afterwards for the next
  # round, which is why they go with the application rather than with the beat.
  has_many :preps, -> { ordered }, class_name: "InterviewPrep", inverse_of: :job_application,
    dependent: :destroy

  # active   → still in play, still worth chasing.
  # offer    → they said yes. Still open, because it isn't decided yet.
  # rejected → they said no.
  # closed   → over by your choice: withdrew, took something else, went cold.
  enum :status, { active: 0, offer: 1, rejected: 2, closed: 3 }

  # Neither rejected nor closed. This is what the index shows unless asked
  # otherwise — "hide the rejected by default".
  #
  # Named because the index needs the same answer in Ruby: a search narrows the
  # chip counts, and those are counted off an already-loaded array rather than
  # re-queried per status. Two copies of "which statuses are live" is exactly
  # the drift that ends with a chip and its own wall disagreeing.
  LIVE_STATUSES = %i[active offer].freeze

  scope :live,    -> { where(status: LIVE_STATUSES) }
  scope :ordered, -> { order(Arel.sql("COALESCE(last_activity_at, created_at) DESC")) }
  scope :engaged, -> { where(id: JobNote.engaged.select(:job_application_id)) }
  scope :unanswered, -> { where.not(id: JobNote.answered.select(:job_application_id)) }

  # The site's autogen palette. A colour is assigned at creation rather than
  # derived at render, because it also rides along onto the calendar and a
  # follow-up written months ago has to keep the colour it was given.
  COLORS = %w[#388bfd #a371f7 #db61a2 #f0883e #e3b341 #3fb950 #34d0e0 #ff7b72].freeze

  # An icon reference: an emoji, a `ti-` class, a `hicon:` pointing at one of
  # the household's uploads, inline SVG, or an image. Anything the shared
  # IconPool speaks — see ApplicationHelper#icon_ref_tag for the rendering.
  # The ceiling is the same one a HouseholdIcon gets, and exists for the one
  # shape that can run away with itself: a pasted image.
  MAX_LOGO_BYTES = 300_000

  before_validation :normalize_fields
  before_validation :assign_color, on: :create

  validates :company, presence: true, length: { maximum: 120 }
  validates :role, length: { maximum: 120 }
  validates :source, length: { maximum: 120 }
  validates :url, length: { maximum: 2_000 }
  validates :color, format: { with: /\A#[0-9a-fA-F]{6}\z/, message: "must be a hex colour" }
  validates :logo, length: { maximum: MAX_LOGO_BYTES }

  # "Acme — Staff Engineer", or just "Acme" when the listing had no title.
  def label
    [company, role].compact_blank.join(" — ")
  end

  # A job is only ever as current as its newest note. Kept as a column so the
  # index can sort without loading every note.
  def touch_activity!
    latest = notes.maximum(:occurred_at)
    update_columns(last_activity_at: latest, updated_at: Time.current)
  end

  # Where the local job hunter answers. Its own default (`web.port`, 8790) on
  # localhost, overridable for the one case that is not his laptop.
  JOBHUNT_HOST = ENV.fetch("JOBHUNT_HOST", "http://localhost:8790").freeze

  # How close behind its receipt an `applied` beat has to land to be read as the
  # same moment, and where a merge puts it. See `settle_merged_applied`.
  MERGE_RECEIPT_WINDOW = 1.hour
  MERGE_APPLIED_LEAD = 5.minutes

  # How far AHEAD of its slot a conversation beat may be stamped and still be
  # read as that meeting's write-up. See `reports_interview?` - a call is logged
  # from the moment it starts, and the clock on the booking is only a plan.
  WRITE_UP_LEAD = 1.hour

  # Two rows for ONE application, folded into one. It keeps happening the same
  # way: jobhunt writes its row the moment it submits, the ATS receipt is
  # proposed as a new row off the mail, and the two land seconds apart with half
  # the timeline on each (JPMorgan, Epicor, Workstream).
  #
  # WHICH ROW SURVIVES is decided here, not by which page the button was on.
  # jobhunt remembers the row it wrote by id (`rails_job_id`) - its "on the
  # board" link and every later note it sends go there - so deleting that one
  # strands it. Its mark on the board is the `applied` note it wrote, source
  # "jobhunt": `Recorder#record` writes that beat onto the very row whose id it
  # then keeps. Nothing points at any other row, so with no mark (or a mark on
  # both) the row being merged from is kept.
  #
  # Returns the row that was kept.
  def merge_with!(other)
    raise ArgumentError, "can't merge an application into itself" if other.id == id
    raise ArgumentError, "#{other.label} belongs to someone else" if other.user_id != user_id

    keep, drop = other.jobhunt_row? && !jobhunt_row? ? [other, self] : [self, other]
    keep.absorb!(drop)
  end

  def jobhunt_row?
    JobNote.exists?(job_application_id: id, tag: :applied, source: "jobhunt")
  end

  # The job's page in the LOCAL job hunter, or nil when it has no row there.
  #
  # Worth having beside `url` rather than instead of it: `url` is the EMPLOYER's
  # posting, which is dead weeks later as often as not, while this is the working
  # copy - the description as it was scraped, the score and why, the answers
  # already given, the letter that was sent. The pointer only ever existed the
  # other way round (jobhunt keeps `rails_job_id` and links out to the board), so
  # reaching the local page from a timeline meant searching jobhunt by company.
  #
  # Only ever reachable from his own machine, which is the point - it is the
  # page he is reading the timeline next to.
  def jobhunt_url
    return nil if jobhunt_job_id.blank?

    "#{JOBHUNT_HOST}/jobs/#{jobhunt_job_id}"
  end

  # This application's own page. Written into the notes of every agenda row a
  # beat here puts on the calendar, which is where the appointment is read from
  # on the day - the timeline, the brief and the recruiter's name are one tap
  # away rather than a search of the board.
  def interview_url
    Rails.application.routes.url_helpers.interview_url(self)
  end

  # What the card shows when there's no logo: the company's first letter over
  # its colour. Two words give two letters, which is enough to tell "Stripe"
  # from "Square" at a glance.
  def initials
    company.to_s.split(/[\s\-&]+/).reject(&:empty?).first(2).map { |w| w[0].upcase }.join
  end

  def dead?
    rejected? || closed?
  end

  # The applications actually IN PLAY: still live, and with at least one beat
  # that only a person on their side could have caused. Most of a job search is
  # rows that were applied to, acknowledged by a machine and never answered,
  # and nothing on this page separated those from the few where something is
  # genuinely happening - the wall sorts by what was touched most recently,
  # which a job-alert digest is as good at as an offer.
  #
  # Deepest first, and within a rung whatever moved most recently. A board is
  # read top down, so the offer belongs at the top of it and the one that has
  # gone quiet at the bottom.
  #
  # The id is the last word because `sort_by` is NOT stable: two rows at the
  # same rung whose newest beats land in the same second - which is what two
  # mails read by the same watcher pass looks like - would otherwise swap
  # places between one load and the next.
  def self.in_play_for(user)
    jobs = user.job_applications.live.engaged.includes(:notes).to_a
    jobs.sort_by { |job| [-job.engagement_depth, -job.engaged_at.to_i, -job.id] }
  end

  # How much of the board nobody ever answered, in total and among the ones
  # that went in recently.
  #
  # The number most of a job search actually consists of, and the one nothing
  # on this page said: the wall sorts by what touched a row last, a job-alert
  # digest touches a row, and `in_play_for` above deliberately shows only the
  # handful where something is happening. This is its complement.
  #
  # Both figures, because the big one on its own is unreadable - a batch sent
  # last week has not had time to be answered yet, and without the recent
  # count there is no telling how much of the silence is simply that.
  SILENCE_WINDOW = 1.month

  def self.silence_for(user)
    jobs = user.job_applications.unanswered.includes(:notes).to_a
    cutoff = SILENCE_WINDOW.ago
    { total: jobs.size, recent: jobs.count { |job| job.applied_at.after?(cutoff) } }
  end

  # When this one went in. The `applied` beat where there is one; where there
  # is not, the timeline starts at the ATS receipt instead, which lands the
  # same day as the application it is receipting.
  def applied_at
    sent = notes.select(&:applied?).map(&:occurred_at).min
    sent || notes.map(&:occurred_at).min || created_at
  end

  # How far this one got, as a rung on JobNote::ENGAGEMENT_DEPTH, or nil when
  # nobody has ever answered. The FURTHEST rung rather than the latest beat:
  # the question is how deep this went, and a plain note written afterwards
  # does not undo an interview.
  def engagement_depth
    notes.filter_map { |note| JobNote::ENGAGEMENT_DEPTH[note.tag] }.max
  end

  def engagement_label
    JobNote::DEPTH_LABELS[engagement_depth]
  end

  # How many ROUND TRIPS this has been through. Not a count of notes and not a
  # count of mails: their reply, the times he sent back and the confirmation
  # that follows are three rows and ONE interaction.
  #
  # What finishes a round:
  #
  #   * a meeting getting BOOKED. The whole exchange that produced it - the ask,
  #     the availability, the confirmation - is the one round.
  #   * a meeting HAPPENING. The booking and the call it booked are two rounds,
  #     because they are two separate things that came back from them.
  #   * homework arriving, or an offer.
  #
  # What finishes nothing: his own moves, a machine's receipt, and the plain
  # notes a timeline collects - reminders, calendar confirmations, and the ATS
  # re-sending its own template on a timer.
  #
  # A `scheduled` beat landing while a meeting is still ahead of us is that
  # meeting MOVING - a correction, a re-confirmation, or a rebook after a
  # cancel - so it adds nothing. Once its time has passed the next booking is a
  # new round, which is what keeps a second interview out of the first's count
  # even when nobody wrote the first one up afterwards.
  #
  # The trailing `+ 1` is an exchange they have opened that has not led
  # anywhere yet. A row where the only thing that ever happened is "we would
  # like to talk" has been through one round trip, not none.
  def interaction_count
    rounds     = 0
    meeting_at = nil   # when the booking still ahead of us is, if there is one
    pending    = false # a booking with no time on it, or one awaiting a rebook
    opened     = false # they have said something nothing has come of yet

    notes.sort_by { |note| [note.occurred_at, note.id] }.each do |note|
      case note.tag.to_sym
      when :heard_back, :availability
        opened = true
      when :scheduled
        rounds    += 1 unless pending || meeting_at&.after?(note.occurred_at)
        meeting_at = note.follow_up_at
        pending    = note.follow_up_at.blank?
        opened     = false
      when :cancelled
        pending = true
      # The meeting happening is the only thing that SPENDS a booking. A
      # take-home alongside one does not, or the rebook of a cancelled round
      # would read as a round of its own.
      when :recruiter_call, :interview
        rounds    += 1
        meeting_at = nil
        pending    = false
        opened     = false
      when :take_home, :offer
        rounds += 1
        opened  = false
      end
    end

    rounds + (opened ? 1 : 0)
  end

  # When anything last happened here, for sorting and for saying how long it
  # has been quiet.
  #
  # Off the notes rather than off `last_activity_at`, which is the same answer
  # but only while every write path remembers to call `touch_activity!`. The
  # notes are loaded for the depth anyway, so this costs nothing and cannot
  # report a row quiet for nine days with yesterday's beat sitting on it.
  def engaged_at
    notes.map(&:occurred_at).max || last_activity_at || created_at
  end

  # What the newest beat is asking HIM for, or nil when the next move is
  # theirs. Read off the LAST beat whatever its tag, which is the reading
  # `JobNote.waiting_on_you_for` takes - the two say whose move it is on the
  # same page and must never disagree about it.
  def owed_now
    notes.max_by { |note| [note.occurred_at, note.id] }&.owed
  end

  # The soonest interview still ahead of us, off a `scheduled` note. This is the
  # only fact on a card with a deadline attached, which is why it decides where
  # the card sits on the wall rather than just how it looks.
  #
  # Read in memory: the index loads notes for every card anyway, and asking the
  # database once per row to answer it would be a query per card.
  def next_interview_at
    booked = notes.select { |note| note.scheduled? && note.follow_up_at.present? }
    booked.map(&:follow_up_at).select(&:future?).min
  end

  # HOW THIS ONE HAS FELT, averaged over the conversations he rated.
  #
  # Per question rather than one number, for the reason `JobNote::SENTIMENT`
  # gives: the two come apart, and the useful reading is a row that says "I did
  # well, I did not like them" rather than a 5. `{did_well: 7.5, liked_them: 4.0}`,
  # with a question nobody answered left out entirely.
  #
  # In memory, like `next_interview_at` and for the same reason: the board loads
  # every card's notes already, and a query per row to average two integers is a
  # query per row.
  def sentiment
    rated = notes.select(&:rated?)
    return {} if rated.empty?

    JobNote::SENTIMENT.keys.index_with { |field|
      given = rated.filter_map { |note| note[field] }
      (given.sum.to_f / given.size).round(1) if given.any?
    }.compact
  end

  # One figure for the row, over every answer he gave on every conversation.
  # Deliberately the mean of the ANSWERS and not the mean of the two averages:
  # three calls rated for how they went and one of those also rated for the
  # company is four answers, and weighting the single company score to half the
  # row is how one bad afternoon sinks a job he otherwise likes.
  def sentiment_average
    given = notes.select(&:rated?).flat_map { |note| note.sentiment.values }
    return nil if given.empty?

    (given.sum.to_f / given.size).round(1)
  end

  def rated_conversations
    notes.select(&:rated?).sort_by { |note| [note.occurred_at, note.id] }
  end

  # The interview that has already HAPPENED with nothing recorded since.
  #
  # `next_interview_at` empties the instant a slot passes, which drops the job
  # out of the booked strip and back into plain recency on the very day the page
  # is being opened to write down how it went. This holds it there until a beat
  # is filed after it - a note typed by hand, or the mail that arrived because
  # of it. Either way something is now on the timeline about it.
  #
  # A scheduled note's own `occurred_at` is when it was FILED, which is before
  # the slot it names, so it can never answer for itself.
  def unreported_interview_at
    held = notes.filter_map { |note|
      note.follow_up_at if note.scheduled? && note.follow_up_at&.past?
    }
    return nil if held.empty?

    last = held.max
    return nil if notes.any? { |note| reports_interview?(note, last) }

    last
  end

  # The beat most likely to be written next, for the Type dropdown on the page
  # where notes get written. A guess with a default behind it, never a decision:
  # it is the one field on the form already in view when the body is being
  # typed, so a wrong guess costs a glance.
  #
  # Only the three states where the answer is not in doubt. A booking whose slot
  # has passed is the clearest of them - that is what the page is open FOR - and
  # `heard_back` is the other half of a documented pair: they wrote, and the
  # thing being written down is the reply. Everything else stays `note`, which
  # is a correct answer rather than a failure to guess.
  def expected_next_tag
    return :applied if notes.empty?
    return conversation_tag if unreported_interview_at.present?

    latest = notes.max_by { |note| [note.occurred_at, note.id] }
    latest&.heard_back? ? :responded : :note
  end

  protected

  # Whether this beat says a passed booking has been WRITTEN UP.
  #
  # Anything filed after the slot does, which is the plain reading and was the
  # whole of the rule. A conversation beat is the write-up itself, though, and
  # it is stamped when the call STARTED - so it lands ON the slot rather than
  # after it, and sometimes just ahead of it. brightwheel's recruiter call and
  # the booking it came from both read 11:00, and River's call was logged
  # fifteen minutes before the slot it was booked for. Both rows were held in
  # the booked strip asking how it went, directly above the answer.
  def reports_interview?(note, slot)
    return false if note.occurred_at.blank?
    return true if note.occurred_at >= slot
    return false unless note.recruiter_call? || note.interview?

    note.occurred_at >= slot - WRITE_UP_LEAD
  end

  # Which conversation a passed booking was. Not a guess: the first one with a
  # company is a recruiter call and every one after it is an interview, so the
  # answer is the rung this row has already reached.
  def conversation_tag
    spoken = JobNote::ENGAGEMENT_DEPTH["recruiter_call"]
    engagement_depth.to_i >= spoken ? :interview : :recruiter_call
  end

  # The notes move by `update_all` so nothing re-fires - a note's callbacks are
  # about the moment it was WRITTEN, and moving it is not that. Their ids don't
  # change, so a mail's `job_triage.job_note_id` still points at the right beat.
  def absorb!(other)
    transaction do
      # A blank here is nothing known, so the other row's answer is better. A
      # value on both is a disagreement and this row's is kept.
      [:role, :source, :url, :logo, :jobhunt_job_id].each { |field|
        self[field] = other[field] if self[field].blank?
      }

      JobNote.where(job_application_id: other.id).update_all(
        job_application_id: id,
        updated_at:         Time.current,
      )
      other.reload.destroy!

      settle_merged_applied
      self.status = merged_status(other)
      save!
      notes.reset
      touch_activity!
    end

    self
  end

  private

  def normalize_fields
    self.company = company.to_s.strip
    self.role    = role.to_s.strip.presence
    self.source  = source.to_s.strip.presence
    self.url     = url.to_s.strip.presence
    self.logo    = logo.presence
  end

  def assign_color
    self.color = color.presence || COLORS.sample
  end

  # The submission happened before its receipt, and on a merge the two beats
  # have only just met: each was written onto a row that had no idea the other
  # existed, so neither `JobNote` callback ever compared them.
  #
  # An `applied` stamped after the receipt but within the hour is the time he
  # got round to pressing the button, and moves to five minutes before the
  # receipt. Past the hour it is not obviously the same moment, and is left
  # where it is. Backwards only, and only against the EARLIEST receipt.
  def settle_merged_applied
    receipt = JobNote.where(job_application_id: id, tag: :acknowledged).minimum(:occurred_at)
    return if receipt.nil?

    late = JobNote.where(
      job_application_id: id,
      tag:                :applied,
      occurred_at:        receipt..(receipt + MERGE_RECEIPT_WINDOW),
    )
    late.update_all(occurred_at: receipt - MERGE_APPLIED_LEAD, updated_at: Time.current)
  end

  # The newest beat speaks for the job when it's one that settles it, the same
  # rule `JobNote#settle_application` keeps. Otherwise a row somebody moved off
  # `active` knows something this one doesn't.
  def merged_status(other)
    newest = JobNote.where(job_application_id: id).order(occurred_at: :desc, id: :desc).first
    implied = JobNote::IMPLIED_STATUS[newest&.tag]
    return implied if implied
    return other.status if active? && !other.active?

    status
  end
end
