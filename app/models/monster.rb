# == Schema Information
#
# Table name: monsters
#
#  id           :integer          not null, primary key
#  accuracy     :integer
#  archetype    :integer
#  attack       :integer
#  crit_damage  :integer
#  crit_rate    :integer
#  defense      :integer
#  element      :integer
#  health       :integer
#  image_url    :string
#  last_updated :datetime
#  name         :string
#  resistance   :integer
#  speed        :integer
#  stars        :integer
#  url          :string
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#

class Monster < ApplicationRecord
  has_many :monster_skills

  # HP
  # ATK
  # DEF
  # SPD
  # CRI Rate
  # CRI DMG
  # RES
  # ACC

  enum :element, {
    fire:  0,
    water: 1,
    wind:  2,
    light: 3,
    dark:  4,
  }

  enum :archetype, {
    attack:   0,
    hp:       1,
    support:  2,
    defense:  3,
    material: 4,
  }

  delegate :short_code, to: :class

  def self.short_code(attr_name)
    case attr_name.to_s.gsub(" ", "_").to_sym
    when :HP,       :health      then :HP
    when :ATK,      :attack      then :ATK
    when :DEF,      :defense     then :DEF
    when :SPD,      :speed       then :SPD
    when :CRI_RATE, :crit_rate   then :CRI_RATE
    when :CRI_DMG,  :crit_damage then :CRI_DMG
    when :RES,      :resistance  then :RES
    when :ACC,      :accuracy    then :ACC
    end
  end

  delegate :long_code, to: :class

  def self.long_code(attr_name)
    case attr_name.to_s.gsub(" ", "_").to_sym
    when :HP,       :health      then :health
    when :ATK,      :attack      then :attack
    when :DEF,      :defense     then :defense
    when :SPD,      :speed       then :speed
    when :CRI_RATE, :crit_rate   then :crit_rate
    when :CRI_DMG,  :crit_damage then :crit_damage
    when :RES,      :resistance  then :resistance
    when :ACC,      :accuracy    then :accuracy
    end
  end

  def attr(attr_name)
    case attr_name.to_s.gsub(" ", "_").to_sym
    when :HP,       :health      then health
    when :ATK,      :attack      then attack
    when :DEF,      :defense     then defense
    when :SPD,      :speed       then speed
    when :CRI_RATE, :crit_rate   then crit_rate
    when :CRI_DMG,  :crit_damage then crit_damage
    when :RES,      :resistance  then resistance
    when :ACC,      :accuracy    then accuracy
    end
  end

  def reload_data
    MonsterScraper.update_monster_data(self)
  end
end
