class AddLocationToLogTrackers < ActiveRecord::Migration[5.0]
  def change
    create_table :locations do |t|
      t.string :ip
      t.string :country_code
      t.string :country_name
      t.string :region_code
      t.string :region_name
      t.string :city
      t.string :zip_code
      t.string :time_zone
      t.float :latitude
      t.float :longitude
      t.string :metro_code
    end
    add_reference :log_trackers, :location

    reversible do |migration|
      migration.up do
        LogTracker.uniq_ips.each do |ip|
          location = Location.find_or_create_by(ip: ip)
          LogTracker.where(ip_address: ip).update_all(location_id: location.id)
          not_set = LogTracker.where(location_id: nil)
        end
      end
    end
  end
end
