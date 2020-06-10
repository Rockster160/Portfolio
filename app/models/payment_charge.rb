# == Schema Information
#
# Table name: payment_charges
#
#  id              :integer          not null, primary key
#  user_id         :integer
#  raw             :text
#  cost_in_pennies :string
#  occurred_at     :datetime
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#

class PaymentCharge < ApplicationRecord
  belongs_to :user
end
