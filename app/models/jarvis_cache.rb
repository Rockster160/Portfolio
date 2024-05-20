# == Schema Information
#
# Table name: jarvis_caches
#
#  id         :bigint           not null, primary key
#  data       :jsonb
#  key        :string
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  user_id    :bigint
#
class JarvisCache < ApplicationRecord
  serialize :data, coder: ::SafeJsonSerializer
  attr_accessor :skip_save_set

  # TODO: Encrypt data in the next life

  belongs_to :user

  def to_param
    key || id
  end

  def self.by(key)
    if key.to_s.match?(/^\d+$/)
      find_by(key: key) || find_by(id: key) || find_or_create_by(key: key)
    else
      find_or_create_by(key: key)
    end
  end

  def self.get(key)
    by(key).data || {}
  end

  def self.dig(*steps)
    key, *rest = steps
    get(key).dig(*rest)
  end

  def self.set(key, val)
    by(key).update(data: val) && val
  end

  def self.dig_set(*steps, val)
    key, *rest = steps
    by(key).dig_set(*rest, val)
  end

  def wrap_data
    { key => (data || {}) }
  end

  def wrap_data=(new_data)
    new_data.each do |key, val|
      user.jarvis_caches.set(key, val)
    end
    self.destroy unless new_data.stringify_keys.include?(self.key.to_s)
  end

  def dig(*steps)
    (data || {}).dig(*steps)
  end

  def set(key, val)
    old_data = reload.data || {}
    old_data[key.to_s] = val

    @skip_save_set ? val : !!update(data: old_data)
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
    @skip_save_set ? val : save
  end
end
