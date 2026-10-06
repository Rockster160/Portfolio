class Jil::GPTPresetsController < ApplicationController
  before_action :authorize_user

  def index
    @presets = current_user.gpt_presets.ordered
  end

  def new
    @preset = current_user.gpt_presets.new

    render :form
  end

  def edit
    @preset = current_user.gpt_presets.find(params[:id])

    render :form
  end

  def create
    @preset = current_user.gpt_presets.new(preset_params)

    if @preset.save
      redirect_to :jil_gpt_presets, notice: "Saved #{@preset.name}"
    else
      render :form, status: :unprocessable_entity
    end
  end

  def update
    @preset = current_user.gpt_presets.find(params[:id])

    if @preset.update(preset_params)
      redirect_to :jil_gpt_presets, notice: "Saved #{@preset.name}"
    else
      render :form, status: :unprocessable_entity
    end
  end

  def destroy
    @preset = current_user.gpt_presets.find(params[:id])
    @preset.destroy

    redirect_to :jil_gpt_presets, notice: "Deleted #{@preset.name}"
  end

  private

  def preset_params
    params.require(:gpt_preset).permit(:name, :instructions)
  end
end
