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

  # A question is answerable on the NEXT thing the person says, and nothing
  # after that. Say anything else and it's been passed over.
  #
  # There is deliberately no clock here. Hundreds of messages can go by in three
  # days, and the length of that gap says nothing about whether an answer is
  # still owed - what says it is whether they've spoken since without answering.
  # Chelsea asked "Are we leaving at 5:30?" on Aug 3; it stayed listed as open
  # through four days of unrelated conversation, and a stray "Tick" from the CLI
  # got passed back to her as Rocco's answer. One intervening message would have
  # closed it, and there were hundreds.
  #
  # The current turn's message is already saved by the time context is built, so
  # ONE message after the question is the answering opportunity and TWO means it
  # was passed over. Something they explicitly bring back up later isn't this
  # tool's job - that's a fresh message to the person, which is what it would be
  # anyway once the question has gone cold.
  def self.open_questions_for(user, conversation: nil)
    scope  = awaiting_answer.where(to_user_id: user.id).order(created_at: :asc)
    cutoff = passed_over_cutoff(conversation)
    cutoff ? scope.where(created_at: cutoff..) : scope
  end

  # When the person last spoke BEFORE the message being answered right now.
  # Anything delivered before that has had its turn go by. Nil when they've said
  # at most one thing, which is the fresh-thread case where nothing has been
  # passed over yet.
  def self.passed_over_cutoff(conversation)
    return nil if conversation.nil?

    conversation.byte_messages
      .where(direction: :outbound)
      .where("byte_messages.metadata->>'hidden' IS DISTINCT FROM 'true'")
      .order(created_at: :desc).limit(2).pluck(:created_at).second
  end
end
