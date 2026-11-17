# == Schema Information
#
# Table name: locations
#
#  id           :integer          not null, primary key
#  city         :string
#  country_code :string
#  country_name :string
#  ip           :string
#  latitude     :float
#  longitude    :float
#  metro_code   :string
#  region_code  :string
#  region_name  :string
#  time_zone    :string
#  zip_code     :string
#

class Location < ApplicationRecord
  has_many :log_trackers

  after_create :geolocate

  def geolocate
    located = Geolocate.lookup(ip) rescue nil
    return unless located

    self.ip = located.ip
    self.country_code = located.country_code
    self.country_name = located.country_name
    self.region_code = located.region_code
    self.region_name = located.region_name
    self.city = located.city
    self.zip_code = located.zip_code
    self.time_zone = located.time_zone
    self.latitude = located.latitude
    self.longitude = located.longitude
    self.metro_code = located.metro_code
    save
  end
  # l = Location.create(ip: "91.230.47.3")
end
