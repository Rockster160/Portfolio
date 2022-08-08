# == Schema Information
#
# Table name: contacts
#
#  id         :bigint           not null, primary key
#  address    :text
#  lat        :float
#  lng        :float
#  name       :text
#  phone      :text
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  user_id    :bigint
#
class Contact < ApplicationRecord
  belongs_to :user

  def loc
    [lat, lng]
  end

  def loc=(*new_loc)
    new_lat, new_lng = *Array.wrap(new_loc).flatten
    self.lat = new_lat
    self.lng = new_lng
  end
end
