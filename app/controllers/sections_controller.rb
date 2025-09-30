class SectionsController < ApplicationController
  before_action :set_list
  before_action :set_section, only: [:edit, :update, :destroy]

  def create
    @section = @list.sections.new(section_params)

    if @section.save
      trigger(:added, @section)
      redirect_to @list, notice: "Section created."
    else
      redirect_to @list, alert: @section.errors.full_messages.join(", ")
    end
  end

  def update
    if @section.update(section_params)
      trigger(:changed, @section)
      redirect_to @list, notice: "Section updated."
    else
      redirect_to @list, alert: @section.errors.full_messages.join(", ")
    end
  end

  def destroy
    @section.destroy
    trigger(:removed, @section)
    redirect_to @list, notice: "Section deleted."
  end

  private

  def trigger(action, section)
    # added | changed | removed
    return if section.blank?

    ::Jil.trigger(current_user, :section, section.with_jil_attrs(action: action))
  end

  def set_list
    @list = List.find(params[:list_id])
  end

  def set_section
    @section = @list.sections.find(params[:id])
  end

  def section_params
    params.require(:section).permit(:name, :color)
  end
end
