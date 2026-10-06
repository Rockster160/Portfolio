# == Schema Information
#
# Table name: gpt_presets
#
#  id           :bigint           not null, primary key
#  user_id      :bigint           not null
#  name         :text             not null
#  instructions :text             not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#
class GPTPreset < ApplicationRecord
  belongs_to :user

  validates :name, presence: true, uniqueness: { scope: :user_id, case_sensitive: false }
  validates :instructions, presence: true

  scope :ordered, -> { order(Arel.sql("LOWER(name)")) }

  def self.named(name)
    find_by("LOWER(name) = ?", name.to_s.squish.downcase)
  end
end
