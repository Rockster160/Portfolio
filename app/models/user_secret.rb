# == Schema Information
#
# Table name: user_secrets
#
#  id         :bigint           not null, primary key
#  name       :text             not null
#  value      :text             not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  user_id    :bigint           not null
#
class UserSecret < ApplicationRecord
  belongs_to :user

  encrypts :value

  validates :name, presence: true, uniqueness: { scope: :user_id, case_sensitive: false }
  validates :value, presence: true

  scope :ordered, -> { order(Arel.sql("LOWER(name)")) }

  def self.named(name)
    find_by("LOWER(name) = ?", name.to_s.squish.downcase)
  end

  def hint
    "…#{value.to_s.last(4)}"
  end
end
