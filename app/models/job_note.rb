# == Schema Information
#
# Table name: job_notes
#
#  id                 :bigint           not null, primary key
#  body               :text             not null
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
  }

  TAG_LABELS = {
    "note"           => "Note",
    "applied"        => "Applied",
    "heard_back"     => "Heard back",
    "recruiter_call" => "Recruiter call",
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

  before_validation :normalize_fields

  validates :body, presence: true, length: { maximum: MAX_BODY }
  validates :occurred_at, presence: true
  validates :source, :spoke_to, length: { maximum: 120 }
  validates :url, length: { maximum: 2_000 }
  validates :duration_minutes,
    numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 24 * 60 },
    allow_nil:    true

  # Oldest first. A thread read backwards is read wrong.
  scope :ordered, -> { order(occurred_at: :asc, id: :asc) }

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

  # Owed now: due today, or already missed.
  scope :due_now, ->(at=Time.current) { where(follow_up_at: ..at.end_of_day) }

  after_commit :sync_follow_up, on: [:create, :update]
  after_commit :retire_follow_up, on: :destroy
  after_commit :settle_application

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
    self.body     = body.to_s.strip
    self.source   = source.to_s.strip.presence
    self.url      = url.to_s.strip.presence
    self.spoke_to = spoke_to.to_s.strip.presence
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

    item = agenda.agenda_items.create(follow_up_attrs.merge(kind: :task, status: :confirmed))
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

  def follow_up_attrs
    {
      name:     "Follow up: #{job_application.company}",
      start_at: follow_up_at,
      notes:    body.to_s.truncate(500),
      color:    job_application.color,
    }
  end

  # Somewhere local and writable. A Google-managed calendar is deliberately
  # skipped: it only accepts events, and a follow-up is a task.
  def follow_up_agenda
    agendas = job_application.user.editable_agendas.where(source: :user).order(:id).to_a
    return nil if agendas.empty?

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

  def newest_note?
    job_application.notes.maximum(:occurred_at).to_i <= occurred_at.to_i
  end
end
