class Jil::HealthController < ApplicationController
  before_action :authorize_user

  def show
    @admin = current_user.admin?
    @view_scope = @admin && params[:scope] == "all" ? :all : :mine
    @health = ::Jil::Health.new(current_user, view_scope: @view_scope)
  end
end
