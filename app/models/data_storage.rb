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
class DataStorage < ApplicationRecord
  serialize :data, SafeJsonSerializer

  def self.[](key)
    find_or_create_by(name: key)
  end

  def self.[]=(key, new_data)
    storage = find_or_create_by(name: key)
    storage.update(data: new_data)
    storage
  end
end
