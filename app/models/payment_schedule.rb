# == Schema Information
#
# Table name: payment_schedules
#
#  id               :integer          not null, primary key
#  user_id          :integer
#  name             :string
#  description      :string
#  cost_in_pennies  :integer
#  recurrence_start :datetime
#  recurrence_date  :integer
#  recurrence_wday  :integer
#  recurrence_type  :integer
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#

class PaymentSchedule < ApplicationRecord
  belongs_to :user
end
