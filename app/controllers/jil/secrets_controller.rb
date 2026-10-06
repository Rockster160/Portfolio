# Write-only: a value goes in and never comes back out to the page. Saving a
# name that already exists replaces its value.
class Jil::SecretsController < ApplicationController
  before_action :authorize_user

  def index
    @secrets = current_user.secrets.ordered
  end

  def create
    name = params[:name].to_s.squish
    secret = current_user.secrets.named(name) || current_user.secrets.new(name: name)

    if secret.update(value: params[:value].to_s.strip)
      redirect_to :jil_secrets, notice: "Saved #{secret.name}"
    else
      redirect_to :jil_secrets, alert: secret.errors.full_messages.to_sentence
    end
  end

  def destroy
    secret = current_user.secrets.find(params[:id])
    secret.destroy

    redirect_to :jil_secrets, notice: "Removed #{secret.name}"
  end
end
