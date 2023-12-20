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

  def dig(*steps)
    (data || {}).dig(*steps)
  end

  def set(key, val)
    old_data = reload.data || {}
    old_data[key.to_s] = val

    !!update(data: old_data)
  end

  def dig_set(*steps, val)
    raise "Not working with numerics" if steps.any? { |step| step.is_a?(Numeric) }
    hash = (self.data ||= {})
    steps.each_with_index { |step, idx|
      if idx < steps.length-1
        # hash[step] ||= step.is_a?(Numeric) ? [] : {}
        hash[step] ||= {}
        hash = hash[step]
      else
        hash[step] = val
      end
    }
    save && val
  end
end
