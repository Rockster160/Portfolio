# == Schema Information
#
# Table name: payment_charges
#
#  id                  :integer          not null, primary key
#  user_id             :integer
#  payment_category_id :integer
#  payment_group_id    :integer
#  raw                 :text
#  amount_in_pennies   :string
#  occurred_at         :datetime
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#

class PaymentCharge < ApplicationRecord
  belongs_to :user
  belongs_to :payment_category, optional: true
  belongs_to :payment_group
end
