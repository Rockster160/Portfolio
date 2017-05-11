# == Schema Information
#
# Table name: monster_skills
#
#  id          :integer          not null, primary key
#  monster_id  :integer
#  name        :string
#  description :text
#  stat        :string
#

class MonsterSkill < ApplicationRecord
  belongs_to :monster
end
