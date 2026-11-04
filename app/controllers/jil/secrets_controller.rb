# Write-only: a value goes in and never comes back out to the page. Saving a
# name that already exists replaces its value. Editing renames it, and rolls the
# value only when a new one is given.
class Jil::SecretsController < ApplicationController
  before_action :authorize_user

  def index
    @secrets = current_user.secrets.ordered
  end

  def edit
    @secret = current_user.secrets.find(params[:id])
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

  def update
    @secret = current_user.secrets.find(params[:id])
    @secret.name = params[:name].to_s.squish
    value = params[:value].to_s.strip
    @secret.value = value if value.present?

    if @secret.save
      redirect_to :jil_secrets, notice: "Saved #{@secret.name}"
    else
      flash.now[:alert] = @secret.errors.full_messages.to_sentence
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    secret = current_user.secrets.find(params[:id])
    secret.destroy

    redirect_to :jil_secrets, notice: "Removed #{secret.name}"
  end
end
