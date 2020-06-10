# == Schema Information
#
# Table name: payment_categories
#
#  id      :integer          not null, primary key
#  user_id :integer
#  name    :string
#

class PaymentCategory < ApplicationRecord
  belongs_to :user
  has_many :payment_charges
end
