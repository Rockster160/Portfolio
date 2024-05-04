class QuickActionsController < ApplicationController
  include AuthHelper
  include QuickActionsHelper

  layout "quick_actions"

  skip_before_action :verify_authenticity_token
  before_action :authorize_user_or_guest

  helper_method :current_user, :user_signed_in?

  def show
    @page = current_user.jarvis_page
  end

  def update
    @page = current_user.jarvis_page
    ::WebPushNotifications.update_count(current_user)
    @page.update(blocks: params.permit!.to_h[:blocks]) if params.key?(:blocks)

    head :ok
  end

  def sync_badge

    head :ok
  end

  def render_widget
    widget_hex = SecureRandom.hex(4)
    widget_data = params.permit!.to_h.except(:action, :controller)
    widget_html = render_to_string(
      partial: widget_data[:type],
      locals: { widget_data: widget_data, hex: widget_hex }
    )
    modal_html = (
      case widget_data[:type].to_sym
      when :buttons
        render_to_string(
          partial: "widget_modal",
          locals: { widget_data: widget_data, modal_id: "modal-#{widget_hex}" }
        )
      # Command modal currently expects modal to be present on load
      # when :jarvis
      #   render_to_string(
      #     partial: "widget_modal",
      #     locals: { widget_data: widget_data, modal_id: "modal-#{widget_hex}" }
      #   )
      end
    )

    render json: { html: widget_html, modal: modal_html }
  end
end
