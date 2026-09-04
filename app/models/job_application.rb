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
end
