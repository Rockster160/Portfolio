# == Schema Information
#
# Table name: venmo_recurrings
#
#  id           :integer          not null, primary key
#  active       :boolean          default(TRUE)
#  amount_cents :integer
#  day_of_month :integer
#  from         :string
#  hour_of_day  :integer
#  note         :string
#  to           :string           default("3852599640")
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#

class VenmoRecurring < ApplicationRecord
  scope :now, -> {
    current = Time.current.in_time_zone("Mountain Time (US & Canada)")

    where(day_of_month: current.day, hour_of_day: current.hour)
  }

  def title
    "Charge (#{to}) $#{amount_dollars} every #{day_of_month} at #{hour_of_day}:00"
  end

  def amount_dollars
    (amount_cents/100.to_f).round(2)
  end

  def charge
    return false unless to == "3852599640"

    Venmo.charge(from, amount_dollars, note)
  end
end
