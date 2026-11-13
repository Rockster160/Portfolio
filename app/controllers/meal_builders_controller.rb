class MealBuildersController < ApplicationController
  include HomeScreenInstall

  skip_before_action :verify_authenticity_token
  before_action :authorize_user_or_guest, except: [:manifest, :icon]
  before_action :set_meal_builder, only: [:show, :edit, :update, :destroy]
  before_action :set_installed_builder, only: [:manifest, :icon]

  layout "quick_actions", only: [:show]

  def index
    @meal_builders = current_user.meal_builders.order(created_at: :desc)
  end

  def show
  end

  # The builder's own install manifest, so one added to a home screen opens
  # on itself, named after itself, wearing the icon picked on its edit page.
  def manifest
    render_install_manifest(
      @meal_builder,
      id:          "meal-builder-#{@meal_builder.id}",
      path:        meal_builder_path(@meal_builder),
      icon_src:    helpers.home_screen_icon_url(@meal_builder),
      description: "Meal Builder: #{@meal_builder.name}",
    )
  end

  def icon
    send_home_screen_icon(@meal_builder)
  end

  def new
    @meal_builder = current_user.meal_builders.new
    render :form
  end

  def edit
    render :form
  end

  def create
    @meal_builder = current_user.meal_builders.new(meal_builder_params)

    if @meal_builder.save
      redirect_to @meal_builder
    else
      render :form
    end
  end

  def update
    if @meal_builder.update(meal_builder_params)
      respond_to do |format|
        format.html { redirect_to @meal_builder }
        format.json { render json: @meal_builder, status: :ok }
      end
    else
      render :form
    end
  end

  def destroy
    @meal_builder.destroy
    redirect_to meal_builders_path
  end

  private

  def set_meal_builder
    @meal_builder = current_user.meal_builders.find_by!(parameterized_name: params[:id])
  end

  def set_installed_builder
    @meal_builder = find_installed(MealBuilder)
    head(:not_found) if @meal_builder.nil?
  end

  def meal_builder_params
    permitted = [:name, :icon, :icon_color, :icon_data_url]
    params.require(:meal_builder).permit(*permitted).tap { |whitelisted|
      if params[:meal_builder][:items].is_a?(String)
        whitelisted[:items] = params[:meal_builder][:items]
      elsif params[:meal_builder][:items].present?
        whitelisted[:items] = params[:meal_builder][:items].map(&:permit!)
      end
    }
  end
end
