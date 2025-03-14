# == Schema Information
#
# Table name: data_storages
#
#  id         :bigint           not null, primary key
#  data       :text
#  name       :string
#  created_at :datetime         not null
#  updated_at :datetime         not null
#

# This should only be used for TRUE global storage, such as `last_sha`
# Personal storage should use UserCache
class DataStorage < ApplicationRecord
  json_serialize :data, coder: ::BetterJsonSerializer

  def self.[](key)
    get(key)
  end

  def self.[]=(key, new_data)
    set(key, new_data)
  end

  def self.get(key)
    storage = find_or_create_by(name: key)
    storage.data
  end

  def self.set(key, new_data)
    storage = find_or_create_by(name: key)
    storage.update(data: new_data)
    storage.data
  end
end
