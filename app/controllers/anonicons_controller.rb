Mime::Type.register "image/png", :png
class AnoniconsController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :set_anonicon

  rescue_from NoMethodError, with: :blank_response

  def index
    render partial: "show" if request.xhr?
  end

  def show
    inline_response
  end

  private

  def inline_response
    send_data @anonicon.raw.to_blob, type: "image/png", disposition: "inline", stream: true
  end

  def set_anonicon
    anonicon_source = params[:id] || request.ip
    @anonicon_source = anonicon_source.sub(/\.(jpe?g|png|gif|bmp)$/i, "")
    @anonicon = Anonicon.generate(@anonicon_source)
  end

  def blank_response
    send_data "", type: "image/png", disposition: "inline", stream: true
  end
end
