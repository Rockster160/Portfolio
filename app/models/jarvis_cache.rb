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
  belongs_to :user

  def get(key)
    (data || {})[key.to_s]
  end

  def set(key, new_data)
    data ||= {}
    data[key.to_s] = new_data

    !!update(data: data)
  end
end
