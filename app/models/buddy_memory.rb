# == Schema Information
#
# Table name: buddy_memories
#
#  id         :bigint           not null, primary key
#  content    :text             not null
#  metadata   :jsonb            not null
#  priority   :integer          default(0), not null
#  tags       :jsonb            not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  user_id    :bigint           not null
#
class BuddyMemory < ApplicationRecord
  belongs_to :user

  scope :recent, -> { order(created_at: :desc) }

  validates :content, presence: true, length: { maximum: 500 }
end
