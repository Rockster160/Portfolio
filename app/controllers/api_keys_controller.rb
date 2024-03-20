class ApiKeysController < ApplicationController
  def index
    @api_keys = current_user.api_keys.order(last_used_at: :desc, created_at: :desc)
  end

  def new
    @api_key = current_user.api_keys.new

    render :form
  end

  def create
    @api_key = current_user.api_keys.new

    if @api_key.update(api_key_params)
      redirect_to :api_keys, notice: "Successfully created"
    else
      redirect_to :api_keys, alert: "Failed to create"
    end
  end

  def edit
    @api_key = current_user.api_keys.find(params[:id])

    render :form
  end

  def update
    @api_key = current_user.api_keys.find(params[:id])

    if @api_key.update(api_key_params)
      redirect_to :api_keys, notice: "Successfully updated"
    else
      redirect_to :api_keys, alert: "Failed to update"
    end
  end

  def destroy
    @api_key = current_user.api_keys.find(params[:id])

    if @api_key.update(enabled: false)
      redirect_to :api_keys, notice: "Successfully disabled"
    else
      redirect_to :api_keys, alert: "Failed to destroy"
    end
  end

  private

  def api_key_params
    params.require(:api_key).permit(
      :name,
    ).tap { |whitelist|
      params.dig(:api_key, :key).presence&.tap { |key|
        whitelist[:key] = key unless @api_key.persisted?
      }
    }
  end
end
