# == Schema Information
#
# Table name: venmos
#
#  id            :integer          not null, primary key
#  access_code   :string(255)
#  access_token  :string(255)
#  expires_at    :datetime
#  refresh_token :string(255)
#  created_at    :datetime
#  updated_at    :datetime
#

# To create a new Venmo, visit `/venmo/auth`
# Call Venmo.charge(from, amount, note)
class Venmo < ApplicationRecord
  class << self
    def charge(from, amount, note)
      Venmo.first.charge(from, amount, note)
    end
  end

  def charge(from, amount, note)
    SmsWorker.perform_async('3852599640', "Charging #{from}")
    refresh_access_token if expired?
    response = HTTParty.post("https://api.venmo.com/v1/payments", body: {
      "access_token" => access_token,
      "phone" => from,
      "note" => note,
      "amount" => amount
    })
    if response['error'].present?
      SmsWorker.perform_async('3852599640', "Venmo Error: #{response['error']['message']}")
    end
  end

  def expired?
    return true if expires_at.nil?
    DateTime.current > expires_at
  end

  private

  def get_access_token
    return false if access_code.nil?
    post_to_venmo({code: access_code})
  end

  def refresh_access_token
    return get_access_token if refresh_token.nil?
    post_to_venmo({refresh_token: refresh_token})
  end

  def post_to_venmo(extra_params)
    response = HTTParty.post("https://api.venmo.com/v1/oauth/access_token", body: {
      client_id: 3191,
      client_secret: ENV["PORTFOLIO_VENMO_SECRET"]
    }.merge(extra_params))
    venmo_params = {}
    venmo_params[:expires_at] = DateTime.current + response["expires_in"].to_i.seconds if response['expires_at'].present?
    venmo_params[:refresh_token] = response["refresh_token"] if response['refresh_token'].present?
    venmo_params[:access_token] = response["access_token"] if response['access_token'].present?
    update(venmo_params)
  end

end
