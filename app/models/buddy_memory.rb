# A persistent thing Buddy remembers about the user across conversations.
# Written by the `[[remember: <fact>]]` side-effect marker; read into
# Buddy's system prompt on every turn so recall is automatic.
#
# `priority` is a small int nudging which memories survive when we later
# add a rollup / decay pass. Not currently sorted-by beyond created_at.
class BuddyMemory < ApplicationRecord
  belongs_to :user

  scope :recent, -> { order(created_at: :desc) }

  validates :content, presence: true, length: { maximum: 500 }
end
