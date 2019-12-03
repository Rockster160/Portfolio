class NfcsController < ApplicationController
  skip_before_action :verify_authenticity_token

  def show
    @nfc = params[:nfc] || "N/A"
    return unless params[:nfc].present?

    ActionCable.server.broadcast "nfc_channel", message: params[:nfc].to_s
  end
end
