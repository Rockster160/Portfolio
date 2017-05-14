# == Schema Information
#
# Table name: monsters
#
#  id           :integer          not null, primary key
#  name         :string
#  url          :string
#  image_url    :string
#  element      :integer
#  archetype    :integer
#  health       :integer
#  attack       :integer
#  defense      :integer
#  speed        :integer
#  crit_rate    :integer
#  crit_damage  :integer
#  resistance   :integer
#  accuracy     :integer
#  last_updated :datetime
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

  enum element: {
    fire:  0,
    water: 1,
    wind:  2,
    light: 3,
    dark:  4
  }

  enum archetype: {
    attack:   0,
    hp:       1,
    support:  2,
    defense:  3,
    material: 4
  }

  def short_code; self.class.short_code; end
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

  def long_code; self.class.long_code; end
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
