# == Schema Information
#
# Table name: monster_skills
#
#  id                :integer          not null, primary key
#  monster_id        :integer
#  name              :string
#  description       :text
#  muliplier_formula :string
#  sort_order        :integer
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#

class MonsterSkill < ApplicationRecord
  belongs_to :monster

  default_scope { order(:sort_order) }

  before_save :set_sort_order

  private

  def set_sort_order
    self.sort_order ||= monster.monster_skills.count
  end

end
