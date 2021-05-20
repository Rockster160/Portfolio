class VenmoRecurringsController < ApplicationController
  before_action :authorize_admin
  before_action :set_venmo, except: [:index, :new, :create]

  def index
    @venmos = VenmoRecurring.order(:created_at)
  end

  def show
  end

  def new
    @venmo = VenmoRecurring.new

    render :form
  end

  def create
    @venmo = VenmoRecurring.new(venmo_params)

    if @venmo.save
      redirect_to venmo_recurrings_path
    else
      render :form
    end
  end

  def edit
    render :form
  end

  def update
    if @venmo.update(venmo_params)
      redirect_to venmo_recurrings_path
    else
      render :form
    end
  end

  def destroy
    if @venmo.destroy
      redirect_to venmo_recurrings_path
    else
      redirect_to venmo_recurrings_path, alert: "Failed to delete venmo: #{@venmo.errors.full_messages.join("\n")}"
    end
  end

  private

  def set_venmo
    @venmo ||= VenmoRecurring.find(params[:id])
  end

  def venmo_params
    params.require(:venmo_recurring).permit(
      :active,
      :amount_cents,
      :day_of_month,
      :from,
      :hour_of_day,
      :note,
      :to,
    )
  end
end
