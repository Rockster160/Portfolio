class Api::V1::SectionsController < Api::V1::BaseController
  skip_before_action :verify_authenticity_token
  before_action :authorize_user_or_guest

  def index
    sections = current_list_sections
    serialize sections
  end

  def show
    serialize current_section
  end

  def create
    section = current_list_sections.new(section_params)
    section.save
    trigger(:added, section)
    serialize section
  end

  def update
    current_section.update(section_params)
    trigger(:changed, current_section)
    serialize current_section
  end

  def destroy
    current_section.destroy
    trigger(:removed, current_section)
    serialize current_section
  end

  private

  def trigger(action, section)
    return if section.blank?

    ::Jil.trigger(current_user, :section, section.with_jil_attrs(action: action))
  end

  def current_list
    @current_list ||= current_user.lists.find_by(id: params[:list_id]) || current_user.lists.by_param(params[:list_id]).take!
  end

  def current_list_sections
    @current_list_sections ||= current_list.sections
  end

  def current_section
    @current_section ||= current_list_sections.find(params[:id])
  end

  def section_params
    params.permit(
      :name,
      :color,
    )
  end
end
