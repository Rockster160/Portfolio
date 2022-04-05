# == Schema Information
#
# Table name: money_buckets
#
#  id          :integer          not null, primary key
#  bucket_json :text
#  user_id     :integer
#

require "json_wrapper"

class MoneyBucket < ApplicationRecord
  belongs_to :user

  serialize :bucket_json, JsonWrapper

  attr_accessor :deposit, :withdraw, :deposit_errors

  def balance
    buckets.sum(&:amount)
  end

  def balance_dollars
    balance.to_f/100
  end

  def adjust=(new_adjust)
    manager.adjust(new_adjust) if new_adjust.present?
  end

  def deposit=(new_deposit)
    manager.deposit(new_deposit) if new_deposit.present?
  end

  def withdraw=(new_withdraw)
    manager.withdraw(new_withdraw) if new_withdraw.present?
  end

  def buckets
    manager.buckets
  end

  def buckets=(attributes)
    self.bucket_json = manager.json_from_form_data(attributes)
  end

  def manager
    @manager ||= MoneyBucketJson.new(self)
  end
end
