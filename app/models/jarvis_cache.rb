# == Schema Information
#
# Table name: jarvis_caches
#
#  id         :bigint           not null, primary key
#  data       :jsonb
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  user_id    :bigint
#
class JarvisCache < ApplicationRecord
  serialize :data, SafeJsonSerializer

  belongs_to :user

  def get(key)
    (data || {})[key.to_s]
  end

  def set(key, val)
    if key.to_s.to_sym == :DoPullups
      Jarvis.ping("Changing Pullups!!! #{val}")
      Jarvis.say("Changing Pullups!!! #{val}") 
    end

    old_data = reload.data || {}
    old_data[key.to_s] = val

    !!update(data: old_data)
  end
end
