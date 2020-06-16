# https://github.com/plaid/plaid-ruby
class PlaidApi
  include HTTParty
  base_uri "https://#{ENV['PORTFOLIO_PLAID_ENV']}.plaid.com"
  headers "Content-Type" => "application/json"

  # ========== Retrieving access_token
  # git clone https://github.com/plaid/quickstart.git
  # cd quickstart/ruby
  # bundle
  # PLAID_CLIENT_ID='***' \
  # PLAID_SECRET='***' \
  # PLAID_PUBLIC_KEY='***' \
  # PLAID_ENV='development' \
  # PLAID_PRODUCTS='transactions' \
  # PLAID_COUNTRY_CODES='US' \
  # ruby app.rb
  # -- Visit `http://localhost:4567`
  # -- Follow steps on page

  class << self
    def client
      @client ||= Plaid::Client.new(
        env:        ENV['PORTFOLIO_PLAID_ENV'],
        client_id:  ENV['PORTFOLIO_PLAID_CLIENT_ID'],
        secret:     ENV['PORTFOLIO_PLAID_SECRET'],
        public_key: ENV['PORTFOLIO_PLAID_PUBLIC_KEY']
      )
    end

    def balance(access_token)
      client.accounts.balance.get(access_token)
    end
  end
end
