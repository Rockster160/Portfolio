class AddressesController < ApplicationController
  before_action :authorize_user, :set_address

  def index
    @addresses = @contact.addresses.order(:created_at)
  end

  def show
  end

  def new
    @address = @contact.addresses.new

    render :form
  end

  def create
    @address = @contact.addresses.new(address_params.merge(user: current_user))

    if @address.save
      redirect_to [:edit, @contact]
    else
      render :form
    end
  end

  def edit
    render :form
  end

  def update
    if @address.update(address_params)
      redirect_to [:edit, @contact]
    else
      render :form
    end
  end

  def destroy
    if @address.destroy
      redirect_to [:edit, @contact]
    else
      redirect_to [:edit, @contact, @address], alert: "Failed to delete address: #{@address.errors.full_messages.join("\n")}"
    end
  end

  private

  def set_address
    @contact = current_user.contacts.find(params[:contact_id])
    @address = @contact.addresses.find(params[:id]) if params[:id].present?
  end

  def address_params
    params.require(:address).permit(
      :primary,
      :street,
      :icon,
      :label,
      :lat,
      :lng,
    )
  end
end
