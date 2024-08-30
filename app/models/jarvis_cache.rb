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
  # TODO: Encrypt `data` in the next life
  attr_accessor :skip_save_set

  belongs_to :user
  has_many :cache_shares

  def to_param
    key || id
  end

  def self.by(key)
    if key.to_s.match?(/^\d+$/)
      find_by(key: key, user: assigned(:user)) || find_by(id: key, user: assigned(:user)) || find_or_create_by(key: key, user: assigned(:user))
    else
      find_or_create_by(key: key, user: assigned(:user))
    end
  end

  def self.get(key)
    by(key).data || {}
  end

  def self.dig(*steps)
    steps = steps.map(&:presence).compact
    key, *rest = steps.map { |s| s.to_s.to_sym }
    rest.none? ? get(key) : get(key).dig(*rest)
  end

  def self.set(key, val)
    by(key).update(data: val) && val
  end

  def self.dig_set(*steps, val)
    key, *rest = steps.map { |s| s.to_s.to_sym }
    by(key).dig_set(*rest, val)
  end

  def wrap_data
    { key => (data || {}) }
  end

  def wrap_data=(new_data)
    new_data.each do |key, val|
      user.caches.set(key, val)
    end
    self.destroy unless new_data.stringify_keys.include?(self.key.to_s)
  end

  def get(*steps)
    steps = steps.map(&:presence).compact
    dig(*steps)
  end

  def dig(*steps)
    steps = steps.map(&:presence).compact
    d = (data || {})
    steps.none? ? d : d.dig(*steps.map { |s| s.to_s.to_sym })
  end

  def set(key, val)
    old_data = reload.data || {}
    old_data[key.to_s] = val

    @skip_save_set ? val : !!update(data: old_data)
  end

  def dig_set(*steps, val)
    steps = steps.map(&:presence).compact
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
