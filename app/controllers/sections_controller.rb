class SectionsController < ApplicationController
  before_action :set_list
  before_action :set_section, only: [:edit, :update, :destroy]

  def create
    @section = @list.sections.new(section_params)

    if @section.save
      redirect_to @list, notice: "Section created."
    else
      redirect_to @list, alert: @section.errors.full_messages.join(", ")
    end
  end

  def update
    if @section.update(section_params)
      redirect_to @list, notice: "Section updated."
    else
      redirect_to @list, alert: @section.errors.full_messages.join(", ")
    end
  end

  def destroy
    @section.destroy
    redirect_to @list, notice: "Section deleted."
  end

  private

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
