# == Schema Information
#
# Table name: contacts
#
#  id               :bigint           not null, primary key
#  address          :text
#  lat              :float
#  lng              :float
#  name             :text
#  nickname         :text
#  phone            :text
#  raw              :jsonb
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  apple_contact_id :text
#  user_id          :bigint
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

  def resync
    return if raw.blank?

    json = raw.deep_symbolize_keys
    # Only relookup loc if address has changed
    # lat, lng = AddressBook.loc_from_name(raw[:addresses].first) || []
    update(
      name: json[:name]&.split(" ", 2)&.first, # Should include aliases and allow last names?
      phone: json[:phones]&.first&.dig(:value)&.gsub(/[^\d]/, "")&.last(10),
      address: json[:addresses]&.first,
      lat: lat,
      lng: lng,
    )
  end
end
