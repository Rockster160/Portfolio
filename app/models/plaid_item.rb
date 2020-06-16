# == Schema Information
#
# Table name: plaid_items
#
#  id                      :integer          not null, primary key
#  user_id                 :integer
#  bank_name               :string
#  plaid_item_id           :text
#  plaid_item_access_token :text
#  created_at              :datetime         not null
#  updated_at              :datetime         not null
#

class PlaidItem < ApplicationRecord
  belongs_to :user

  def balance
    return unless plaid_item_access_token

    @balance ||= PlaidApi.balance(plaid_item_access_token)
  end

  def quick_balance
    balance["accounts"].find do |account_hash|
      account_hash["name"] == "MYFREE CHECKING"
    end.dig("balances", "current")
  end
end
