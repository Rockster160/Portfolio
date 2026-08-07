class CustomChartsController < ApplicationController
  before_action :authorize_user_or_guest
  before_action :set_chart, only: [:show, :data, :edit, :update, :destroy]

  def index
    @charts = current_user.custom_charts
    @charts = @charts.query(params[:q]) if params[:q].present?
    @charts = @charts.where(user: current_user).ordered
  end

  def show
    @payload = @chart.build(**build_overrides)
  end

  def data
    render json: @chart.build(**build_overrides)
  end

  # Builds an unsaved chart from posted config so the editor can preview live.
  def preview
    chart = current_user.custom_charts.new(chart_params)
    render json: chart.build(**build_overrides)
  end

  def new
    @chart = current_user.custom_charts.new(config: CustomChart::DEFAULTS)
  end

  def edit
  end

  def create
    @chart = current_user.custom_charts.new(chart_params)

    if @chart.save
      redirect_to custom_chart_path(@chart)
    else
      render :new, status: :unprocessable_entity
    end
  end

  def update
    if @chart.update(chart_params)
      redirect_to custom_chart_path(@chart)
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @chart.destroy
    redirect_to custom_charts_path
  end

  private

  def set_chart
    @chart = current_user.custom_charts.where(user: current_user).find(params[:id])
  end

  def build_overrides
    {
      start_at: params[:start_date],
      end_at:   params[:end_date],
      bucket:   params[:bucket],
      range:    params[:range],
    }.compact_blank
  end

  def chart_params
    permitted = params.require(:custom_chart).permit(
      :name,
      :query,
      config: [
        :value_source,
        :data_key,
        :series_key,
        :metric,
        :series_by,
        :bucket,
        :chart_type,
        :range,
        :unit,
        :queries,
        :marker_query,
        :colors,
        :invert_sign,
      ],
    )
    permitted[:config] = permitted[:config].to_h if permitted[:config].present?
    permitted
  end
end
