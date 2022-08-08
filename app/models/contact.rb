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
end
