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

  scope :awaiting_answer, -> { where(status: :delivered).where.not(kind: :notify) }

  validates :body, presence: true, length: { maximum: 1000 }

  def question?
    !notify?
  end

  # The recipient's still-open questions, for the per-turn context block that
  # lets their Buddy notice "the user just answered one of these".
  def self.open_questions_for(user)
    awaiting_answer.where(to_user_id: user.id).order(created_at: :asc)
  end
end
