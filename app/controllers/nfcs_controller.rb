class NfcsController < ApplicationController
  skip_before_action :verify_authenticity_token

  def show
    @nfc = params[:nfc] || "--"
    return if params[:nfc].blank?

    ActionCable.server.broadcast :nfc_channel, { message: params[:nfc].to_s }
  end
end
