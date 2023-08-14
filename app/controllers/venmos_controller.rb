class VenmosController < ApplicationController

  def index
    if params[:code].present?
      Venmo.create(access_code: params[:code])
    end

    redirect_to root_path
  end

  def auth
    client_id = '3191'
    scopes = ['make_payments', 'access_profile']
    redirect_to "https://api.venmo.com/v1/oauth/authorize?client_id=#{client_id}&response_type=code&scope=#{scopes.join("%20")}"
  end

end
