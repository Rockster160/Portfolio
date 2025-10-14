Mime::Type.register "image/png", :png
class QrLabelsController < ApplicationController
  before_action :authorize_admin
  skip_before_action :verify_authenticity_token
  before_action :set_qr

  def index
    render partial: "show" if request.xhr?
  end

  def show
    inline_response
  end

  private

  def inline_response
    send_data @qr, type: "image/png", disposition: "inline", stream: true
  end

  def set_qr
    if params[:box_id].present?
      box = current_user.boxes.find(params[:box_id])
      @url = box_url(box, host: "rdjn.me").gsub(/https?:\/\//, "")
      @title = box.name
    end

    @url ||= params[:url]
    @title ||= params[:title]

    return blank_response if @url.blank? || @title.blank?

    @qr = QrLabel.card(@url, title: @title)
  end

  def blank_response
    send_data "", type: "image/png", disposition: "inline", stream: true
  end
end
