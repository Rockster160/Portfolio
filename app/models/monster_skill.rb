# == Schema Information
#
# Table name: monster_skills
#
#  id                :integer          not null, primary key
#  monster_id        :integer
#  name              :string
#  description       :text
#  muliplier_formula :string
#

class MonsterSkill < ApplicationRecord
  belongs_to :monster
  default_scope { order(id: :asc) }
end
