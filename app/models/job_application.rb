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
#  user_id          :bigint           not null
#
class JobApplication < ApplicationRecord
  belongs_to :user
  has_many :notes, -> { ordered }, class_name: "JobNote", inverse_of: :job_application,
    dependent: :destroy

  # active   → still in play, still worth chasing.
  # offer    → they said yes. Still open, because it isn't decided yet.
  # rejected → they said no.
  # closed   → over by your choice: withdrew, took something else, went cold.
  enum :status, { active: 0, offer: 1, rejected: 2, closed: 3 }

  # Neither rejected nor closed. This is what the index shows unless asked
  # otherwise — "hide the rejected by default".
  scope :live,    -> { where(status: [:active, :offer]) }
  scope :ordered, -> { order(Arel.sql("COALESCE(last_activity_at, created_at) DESC")) }

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

  # How close behind its receipt an `applied` beat has to land to be read as the
  # same moment, and where a merge puts it. See `settle_merged_applied`.
  MERGE_RECEIPT_WINDOW = 1.hour
  MERGE_APPLIED_LEAD = 5.minutes

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

  # What the card shows when there's no logo: the company's first letter over
  # its colour. Two words give two letters, which is enough to tell "Stripe"
  # from "Square" at a glance.
  def initials
    company.to_s.split(/[\s\-&]+/).reject(&:empty?).first(2).map { |w| w[0].upcase }.join
  end

  def dead?
    rejected? || closed?
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

  protected

  # The notes move by `update_all` so nothing re-fires - a note's callbacks are
  # about the moment it was WRITTEN, and moving it is not that. Their ids don't
  # change, so a mail's `job_triage.job_note_id` still points at the right beat.
  def absorb!(other)
    transaction do
      # A blank here is nothing known, so the other row's answer is better. A
      # value on both is a disagreement and this row's is kept.
      [:role, :source, :url, :logo].each { |field|
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
