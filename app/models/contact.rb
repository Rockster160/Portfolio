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

  serialize :raw, SafeJsonSerializer

  validates_uniqueness_of :apple_contact_id, allow_nil: true

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

    address = raw[:addresses]&.first
    json = raw.deep_symbolize_keys
    # Only relookup loc if address has changed

    if lat.nil? || (address.present? && address != self.address)
      lat, lng = AddressBook.loc_from_name(address) || []
    end

    update(
      name: json[:name]&.split(" ", 2)&.first, # Should include aliases and allow last names?
      phone: json[:phones]&.first&.dig(:value)&.gsub(/[^\d]/, "")&.last(10),
      address: json[:addresses]&.first,
      nickname: json[:nickname],
      lat: lat,
      lng: lng,
    )
  end
end
