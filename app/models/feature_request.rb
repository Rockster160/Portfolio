# == Schema Information
#
# Table name: feature_requests
#
#  id                   :bigint           not null, primary key
#  body                 :text             not null
#  seen_at              :datetime
#  status               :integer          default("open"), not null
#  title                :string           not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  byte_conversation_id :bigint
#  byte_message_id      :bigint
#  user_id              :bigint           not null

#
# Something a companion was asked for and couldn't do.
#
# The failure this exists to replace is not a refusal, it's the opposite: told
# to keep somebody on a 30-minute rhythm with 10-minute breaks, Suki said the
# breaks were "lined up to pop in every half hour until 6:30 PM" and set one
# countdown, because there was no way to express the rest and describing it was
# nearer to helping than saying no (prod 4136). The same shape has turned up
# against a repeating timer, a per-minute reminder and a UI she can't see.
#
# So a companion now has a third answer besides doing it and declining it: say
# plainly what it can't do, and offer to write it down. That makes the honest
# answer the useful one, and it means the boundary of the app is recorded by
# the people hitting it rather than guessed at later.
class FeatureRequest < ApplicationRecord
  belongs_to :user
  belongs_to :byte_conversation, optional: true
  belongs_to :byte_message,      optional: true

  # open     - written down, nothing decided
  # planned  - going to happen
  # shipped  - it exists now
  # declined - not going to happen, on purpose
  enum :status, { open: 0, planned: 1, shipped: 2, declined: 3 }, prefix: :status

  validates :title, presence: true, length: { maximum: 120 }
  validates :body,  presence: true, length: { maximum: 2000 }

  scope :live,   -> { where(status: [:open, :planned]) }
  scope :recent, -> { order(created_at: :desc) }

  # A request about the same thing, already written down.
  #
  # Only ever consulted among LIVE ones: something shipped or declined is
  # settled, and asking again after that is a real second data point rather
  # than a duplicate. Two shared significant words rather than one, because a
  # single overlap ("timer", "reminder") is how unrelated asks collapse into
  # each other — the lesson from BuddyReminder.cancelled_like, which matched on
  # one and told somebody they'd switched off a reminder they'd never had.
  def self.similar_to(user, title, body)
    words = significant_words("#{title} #{body}")
    return nil if words.length < 2

    live.where(user_id: user.id).recent.find { |row|
      (significant_words("#{row.title} #{row.body}") & words).length >= 2
    }
  end

  FILLER = <<~WORDS.split.to_set.freeze
    a an and be can could for from have i in into is it like me my of on or so
    that the them then they this to want wants when with would you your
  WORDS

  def self.significant_words(text)
    text.to_s.downcase.scan(/[a-z]{3,}/).reject { |w| FILLER.include?(w) }.map(&:singularize).uniq
  end

  # Who hears about it. Every request is about the app, and one person owns the
  # app — so it goes to them, whoever asked. Nil in an install where User.me
  # can't be resolved, which is the eval harness rather than anything real.
  def self.owner
    ::User.me
  end

  def notify_owner?
    self.class.owner.present? && self.class.owner.id != user_id
  end
end
