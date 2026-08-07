# == Schema Information
#
# Table name: buddy_relays
#
#  id                   :bigint           not null, primary key
#  answer               :jsonb
#  answered_at          :datetime
#  body                 :text             not null
#  delivered_at         :datetime
#  kind                 :integer          default("notify"), not null
#  options              :jsonb            not null
#  status               :integer          default("pending"), not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  from_conversation_id :bigint
#  from_user_id         :bigint           not null
#  to_byte_action_id    :bigint
#  to_conversation_id   :bigint
#  to_user_id           :bigint           not null
#
class BuddyRelay < ApplicationRecord
  belongs_to :from_user, class_name: "User"
  belongs_to :to_user,   class_name: "User"
  belongs_to :from_conversation, class_name: "ByteConversation", optional: true
  belongs_to :to_conversation,   class_name: "ByteConversation", optional: true
  belongs_to :to_byte_action,    class_name: "ByteAction", optional: true

  # notify     - "let Chelsea know I fed the dog" (no answer)
  # ask_open   - "ask Chelsea what she wants for dinner" (free text back)
  # ask_choice - "ask Chelsea dishes or mop" (pick one)
  # ask_multi  - "which love languages resonate" (pick any, confirm)
  enum :kind, { notify: 0, ask_open: 1, ask_choice: 2, ask_multi: 3 }

  # pending   - built, not yet delivered
  # delivered - sitting in the recipient's companion, awaiting their answer
  # answered  - recipient responded; answer captured
  # relayed   - answer passed back to the asker
  # cancelled - withdrawn / expired
  enum :status, { pending: 0, delivered: 1, answered: 2, relayed: 3, cancelled: 4 }

  # How long a question stays answerable. Same window the sequence gate uses
  # (Buddy::ProposalBuilder::AWAIT_TTL), because they are two halves of one
  # question: the gate gives up after three days and says nobody answered, and
  # a question the asker has already been told went unanswered is not still
  # open on the other side.
  #
  # Unbounded, it sat in the recipient's context forever waiting to catch
  # anything. Chelsea asked "Are we leaving at 5:30?" on Aug 3; it was never
  # answered and never closed, so it was still listed as open FOUR DAYS later
  # when a stray "Tick" arrived from the CLI - and Buddy, correctly following
  # its instructions about an open question, passed "Tick" back to her as
  # Rocco's answer.
  ANSWER_WINDOW = Buddy::ProposalBuilder::AWAIT_TTL

  scope :awaiting_answer, -> { where(status: :delivered).where.not(kind: :notify) }
  # Still answerable: delivered, a real question, and asked recently enough
  # that an answer would still be about it.
  scope :still_open,      ->(now=Time.current) { awaiting_answer.where(created_at: (now - ANSWER_WINDOW)..) }

  validates :body, presence: true, length: { maximum: 1000 }

  def question?
    !notify?
  end

  def stale?(now=Time.current)
    created_at < now - ANSWER_WINDOW
  end

  # The recipient's still-open questions, for the per-turn context block that
  # lets their Buddy notice "the user just answered one of these".
  def self.open_questions_for(user)
    still_open.where(to_user_id: user.id).order(created_at: :asc)
  end
end
