module Buddy
  # The pinned outstanding strip: what is still standing open, and letting go of
  # one.
  #
  # Dismissing is not resolving and the two must not blur together. Nobody
  # checked the condition here — the person said stop asking. What it buys is
  # the KEY: while an alert stands open it owns its key, so every later
  # occurrence lands on the same buried bubble rather than announcing itself.
  # Without a way out, one ignored alert silently eats every one after it.
  class AlertsController < ApplicationController
    before_action :authorize_user
    before_action :authorize_owner

    def index
      render json: { alerts: Buddy::Alerts.outstanding_wire(current_user) }
    end

    def dismiss
      alert = Buddy::Alerts.dismiss!(user: current_user, id: params[:id])
      return head(:not_found) if alert.nil?

      render json: { alerts: Buddy::Alerts.outstanding_wire(current_user) }
    end

    private

    def authorize_owner
      head :forbidden unless current_user&.byte_access?
    end
  end
end
