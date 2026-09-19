# == Schema Information
#
# Table name: job_notes
#
#  id                 :bigint           not null, primary key
#  body               :text
#  duration_minutes   :integer
#  follow_up_at       :datetime
#  occurred_at        :datetime         not null
#  source             :string
#  spoke_to           :string
#  tag                :integer          default("note"), not null
#  url                :string
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  agenda_item_id     :bigint
#  job_application_id :bigint           not null
#
class JobNote < ApplicationRecord
  belongs_to :job_application

  # The beats of an application. `note` is the default and carries no meaning
  # beyond "this happened"; the rest read as a status in the timeline, and
  # three of them decide the job is over (see `implied_status`).
  #
  # Numbered in the order they were added, never in reading order — the integer
  # is what's in the column. TAG_LABELS below is the order a person sees.
  enum :tag, {
    note:           0,
    applied:        1,
    heard_back:     2,
    recruiter_call: 3,
    interview:      4,
    take_home:      5,
    offer:          6,
    rejected:       7,
    withdrew:       8,
    responded:      9,
    scheduled:      10,
    acknowledged:   11,
    availability:   12,
  }

  # Reading order, and the order of the dropdown. `responded` is the other half
  # of `heard_back`: they wrote, then you wrote back. Which of those two a
  # timeline ends on is the whole question of whether the ball is in your court.
  #
  # `scheduled` sits above `interview` because that's the order they happen in:
  # one books it, the other is it having happened. `availability` sits directly
  # above `scheduled` for the opposite reason - the two are the pair most easily
  # confused, and adjacency in the dropdown is how a person tells them apart.
  #
  # An ask for times is NOT a booking. It is the one beat on this list waiting
  # on HIM: "send me your availability" is a task, and tagging it `scheduled`
  # both says an interview exists that doesn't and offers to put it on the
  # calendar as a timed event.
  #
  # `acknowledged` is the ATS auto-reply, and it needed a tag of its own because
  # neither neighbour is honest about it. `applied` is a thing THEY did, and
  # stamping it on a machine's receipt says they applied twice; `heard_back` is
  # a person writing, which is the beat actually being waited on, and a robot
  # wearing it makes a live application look answered.
  TAG_LABELS = {
    "note"           => "Note",
    "applied"        => "Applied",
    "acknowledged"   => "Acknowledged",
    "heard_back"     => "Heard back",
    "responded"      => "Response",
    "recruiter_call" => "Recruiter call",
    "availability"   => "Availability",
    "scheduled"      => "Scheduled",
    "interview"      => "Interview",
    "take_home"      => "Take-home",
    "offer"          => "Offer",
    "rejected"       => "Rejected",
    "withdrew"       => "Withdrew",
  }.freeze

  # A tag that settles the whole application, not just this moment in it.
  # Logging the rejection IS marking the job rejected — having to then go and
  # change a dropdown saying the same thing is how a tracker goes stale.
  IMPLIED_STATUS = {
    "offer"    => :offer,
    "rejected" => :rejected,
    "withdrew" => :closed,
  }.freeze

  MAX_BODY = 10_000

  # An event needs a length before the calendar will take it. `duration_minutes`
  # is the answer whenever it was given; this is the slot to book when it
  # wasn't, and it's editable on the agenda like any other event.
  DEFAULT_INTERVIEW_MINUTES = 60

  # Where follow-ups and interviews go. A person-facing calendar name, so it's a
  # string, and it's a preference rather than a requirement — an account without
  # one falls back through the agenda default to the oldest writable calendar.
  FOLLOW_UP_AGENDA_NAME = "Tasks".freeze

  before_validation :normalize_fields
  before_validation :settle_applied_before_receipt, on: :create
  # `after_save`, not `after_create`: a note usually becomes a receipt by being
  # RETAGGED, not by being created as one — Buddy::JobMailOffer files arriving
  # mail as a plain `note` and Buddy::Tools add_job_note revises it in place.
  # Gated on the two columns the callback reads so an unrelated touch is free.
  after_save :settle_receipt_after_applied,
    if: -> { acknowledged? && (saved_change_to_tag? || saved_change_to_occurred_at?) }
  # Asking for times again withdraws the booking those times were for.
  # `after_commit`, because retiring the other note's calendar row runs that
  # note's own callbacks.
  after_commit :withdraw_booking, on: [:create, :update],
    if: -> { availability? && previous_changes.key?("tag") }

  # An untagged note IS its words, so it needs some. Every other tag already
  # says what happened — "logged an interview on the 14th" is a whole fact —
  # and demanding a sentence beside it is what produced notes reading "Applied."
  # underneath a chip reading APPLIED.
  validates :body, presence: true, if: :note?
  validates :body, length: { maximum: MAX_BODY }
  validates :occurred_at, presence: true
  validates :source, :spoke_to, length: { maximum: 120 }
  validates :url, length: { maximum: 2_000 }
  validates :duration_minutes,
    numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 24 * 60 },
    allow_nil:    true

  # Oldest first — the order it happened in, which is what everything that
  # reasons about a timeline wants.
  scope :ordered, -> { order(occurred_at: :asc, id: :asc) }

  # Newest first, for reading. `reorder` because the association already carries
  # `ordered`, and appending to it would leave the ascending sort in front and
  # this one doing nothing.
  scope :recent, -> { reorder(occurred_at: :desc, id: :desc) }

  # Everything this person still owes someone, soonest first. Deliberately has
  # no floor: a follow-up you missed last Tuesday is MORE outstanding than one
  # due on Friday, and dropping it off the bottom of the list is how a chase
  # gets forgotten. It leaves on its own when the application does — the merge
  # below takes it out the moment the job stops being live.
  scope :follow_ups_for, ->(user) {
    scope = joins(:job_application).where(job_applications: { user_id: user.id })
    scope = scope.merge(JobApplication.live)
    scope.where.not(follow_up_at: nil).order(:follow_up_at)
  }

  # Owed now: due today in THEIR day, or already missed.
  #
  # The zone is the whole of it. There is no `config.time_zone`, so a bare
  # `Time.current.end_of_day` is midnight UTC - which is 6pm in MDT, and from
  # 6pm onward a follow-up due later the same evening read as "still ahead" and
  # dropped off the count somebody is working from. Nothing announced that; the
  # number just went down for the rest of the evening and came back overnight.
  # Same trap BuddyMemory#waiting_label documents, in the same direction.
  #
  # The user is a required argument rather than a defaulted zone because the
  # only way to get this right is to know whose day is being asked about, and a
  # default would quietly be UTC again.
  scope :due_now, ->(user, at=Time.current) {
    zone = ::ActiveSupport::TimeZone[user&.timezone.to_s] || ::Time.zone
    where(follow_up_at: ..at.in_time_zone(zone).end_of_day)
  }

  after_commit :sync_follow_up, on: [:create, :update]
  after_commit :retire_follow_up, on: :destroy
  after_commit :settle_application
  after_commit :refresh_fitness, on: :create

  def tag_label
    TAG_LABELS[tag] || "Note"
  end

  # "45m", "1h 15m". Nil when nobody said, which is most of them.
  def duration_label
    return nil if duration_minutes.blank?
    return "#{duration_minutes}m" if duration_minutes < 60

    hours, mins = duration_minutes.divmod(60)
    mins.zero? ? "#{hours}h" : "#{hours}h #{mins}m"
  end

  # The calendar row this note's follow-up put on the agenda, if it's still
  # there. Someone deleting it from the agenda is allowed to — a stale id here
  # simply reads as "no follow-up on the calendar" and re-creates on next save.
  def follow_up_item
    return nil if agenda_item_id.blank?

    AgendaItem.find_by(id: agenda_item_id)
  end

  private

  def normalize_fields
    self.occurred_at ||= Time.current
    self.body     = tidy_body
    self.source   = source.to_s.strip.presence
    self.url      = url.to_s.strip.presence
    self.spoke_to = spoke_to.to_s.strip.presence
  end

  # THE SUBMISSION HAPPENED BEFORE THE RECEIPT FOR IT. ALWAYS.
  #
  # `applied` is stamped when he says he sent it, and saying so is a thing he
  # gets to at his own pace - after the tab has loaded, after he has read the
  # confirmation page, sometimes minutes later. The ATS auto-reply is sent by a
  # machine the moment the form lands. So the receipt regularly arrives on the
  # board FIRST, and the timeline reads as though he applied in response to
  # being thanked for applying.
  #
  # Four rows were already like that: Fieldwire by twelve minutes, Instrumentl by
  # seven seconds, JPMorganChase by twenty-five, Epicor by five and a half
  # minutes. The gap is noise in every case - what it is measuring is how long
  # he took to press a button, not anything about the application.
  #
  # So the `applied` beat is moved to just before the earliest receipt, and only
  # ever BACKWARDS. A submission genuinely made after an acknowledgement is not
  # a thing that happens; a submission recorded after one is routine.
  #
  # Only on create, and only against `acknowledged`: a later `heard_back` or
  # `rejected` says nothing about when the form was sent, and rewriting history
  # off those would be inventing rather than correcting.
  #
  # BOTH ORDERS OF WRITING, because either note can be the second one. This
  # first shipped handling only an `applied` written after its receipt, and
  # University of Utah went out of order two hours later: jobhunt wrote
  # `applied` at 5:31:32pm, and the receipt card tapped at 5:44pm stamped the
  # mail's own 5:31:30pm. That is the COMMON order - jobhunt records the
  # submission the moment it happens, and the receipt waits on a tap. Three of
  # the five that were out of order were written that way round.
  def settle_applied_before_receipt
    return unless tag.to_s == "applied"
    return if job_application.nil? || occurred_at.nil?

    receipt = job_application.notes.where(tag: :acknowledged).minimum(:occurred_at)
    return if receipt.nil? || occurred_at < receipt

    self.occurred_at = receipt - 1.second
  end

  # The same rule from the receipt's side: the submissions already on the row
  # that now sit at or after it. `update_all` for the reason the backfill gives
  # - the only change is a clock correction, and `sync_follow_up` and
  # `refresh_fitness` have nothing to answer about one.
  def settle_receipt_after_applied
    receipt = job_application.notes.where(tag: :acknowledged).minimum(:occurred_at)
    late    = job_application.notes.where(tag: :applied, occurred_at: receipt..)
    return if late.update_all(occurred_at: receipt - 1.second, updated_at: Time.current).zero?

    job_application.touch_activity!
  end

  # A company that asks for availability has cancelled whatever was booked.
  #
  # The two notes are different rows: the mail saying "she can no longer meet on
  # the 24th, send more times" lands as its own `availability` note, while the
  # booking lives on the earlier `scheduled` one that holds the agenda item. So
  # retagging the arrival leaves a meeting nobody is going to sitting on the
  # calendar, and nothing in the path that files the mail ever looks at the
  # other row.
  #
  # Clearing `follow_up_at` is the whole of it: `sync_follow_up` on that note
  # sees a blank and retires its agenda item. The note itself stays - it is
  # still the record that an interview was booked - and only the date it is
  # waiting on goes, which is the thing that stopped being true.
  #
  # FUTURE ONLY. An interview that already happened is history, and an
  # availability request weeks later is about the next round rather than a
  # withdrawal of that one.
  def withdraw_booking
    return if job_application.nil?

    booked = job_application.notes.where(tag: :scheduled).where(follow_up_at: Time.current..)
    booked.find_each { |note| note.update(follow_up_at: nil) }
  end

  # Blank lines off the top and bottom, and nothing else. `strip` was doing this
  # job and taking the FIRST line's indentation with it, so a block pasted in
  # already indented came out with line one flush and the rest hanging — ragged
  # in exactly the case the indentation was there to serve.
  #
  # CRLF is normalised because pasted email arrives full of it, and a stray \r
  # is one more invisible character to reason about later.
  def tidy_body
    text = body.to_s.gsub(/\r\n?/, "\n")
    text = text.sub(/\A(?:[ \t]*\n)+/, "")
    text.sub(/\s+\z/, "").presence
  end

  # A follow-up isn't a second reminder system — it's an agenda task, so the
  # notification settings, the day view and the Buddy briefing all pick it up
  # without knowing this feature exists.
  def sync_follow_up
    return retire_follow_up if follow_up_at.blank?

    item = follow_up_item
    return write_follow_up_item if item.nil?

    item.update(follow_up_attrs)
    item.agenda.broadcast!
  end

  def write_follow_up_item
    agenda = follow_up_agenda
    return if agenda.nil?

    item = agenda.agenda_items.create(follow_up_attrs.merge(status: :confirmed))
    return unless item.persisted?

    update_columns(agenda_item_id: item.id, updated_at: Time.current)
    agenda.broadcast!
  end

  def retire_follow_up
    item = follow_up_item
    return if item.nil?

    agenda = item.agenda
    item.destroy
    update_columns(agenda_item_id: nil, updated_at: Time.current) if persisted?
    agenda.broadcast!
  end

  # The row this puts on the agenda. The date means two different things
  # depending on the tag above it: on a `scheduled` note it IS the interview, so
  # it goes on as a timed event where an appointment belongs; on everything else
  # it's a chase you owe them, which is a task.
  #
  # Both shapes are spelled out in full — including `end_at: nil` for a task —
  # so that re-tagging a note converts the item it already wrote instead of
  # leaving an event wearing half of a task's fields.
  def follow_up_attrs
    minutes = duration_minutes || DEFAULT_INTERVIEW_MINUTES
    # What the row on the agenda is FOR. "Follow up: ApartmentIQ" against an ask
    # for times says nothing about what is owed; the whole point of the tag is
    # that there is a specific thing to do.
    prefix  = (
      if scheduled?
        "Interview"
      elsif availability?
        "Send availability"
      else
        "Follow up"
      end
    )

    {
      name:     "#{prefix}: #{job_application.company}",
      kind:     scheduled? ? :event : :task,
      start_at: follow_up_at,
      end_at:   (follow_up_at + minutes.minutes if scheduled?),
      notes:    body.to_s.truncate(500).presence,
      color:    job_application.color,
    }
  end

  # Somewhere local and writable. A Google-managed calendar is deliberately
  # skipped: a follow-up is a task and Google only takes events, and even the
  # interview — which IS an event — would have to be written to Google first
  # and mirrored back rather than created here.
  #
  # A calendar called "Tasks" wins outright, ahead of the general default: this
  # code is naming a destination, and the preference is for when nobody does.
  # Matched loosely because a calendar name is typed by a person — one on this
  # account ends in a space.
  def follow_up_agenda
    agendas = job_application.user.editable_agendas.where(source: :user).order(:id).to_a
    return nil if agendas.empty?

    named = agendas.find { |a| a.name.to_s.strip.casecmp?(FOLLOW_UP_AGENDA_NAME) }
    return named if named

    preferred = AgendaPreference.for(job_application.user).default_agenda_id
    agendas.find { |a| a.id == preferred.to_i } || agendas.first
  end

  # Only the newest note gets to speak for the application. Back-filling an
  # interview from three weeks ago shouldn't reopen a job that was rejected
  # since, and typing up an old rejection shouldn't close a live one.
  def settle_application
    implied = IMPLIED_STATUS[tag]
    return if implied.nil?
    return if destroyed?
    return unless newest_note?
    return if job_application.status.to_s == implied.to_s

    job_application.update(status: implied)
  end

  # The dashboard's daily rows are PUSHED. The Fitness cell refreshes itself
  # only at midnight, and the one thing that rebroadcasts it is an ActionEvent
  # landing — so the applications row, which is neither, says so itself or
  # sits a day stale on a wall somebody is reading to decide whether they are
  # done for the day.
  def refresh_fitness
    return unless applied?
    return unless job_application.user&.me?

    ::FitnessBroadcast.broadcast
  end

  def newest_note?
    job_application.notes.maximum(:occurred_at).to_i <= occurred_at.to_i
  end
end
