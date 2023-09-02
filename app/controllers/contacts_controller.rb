class ContactsController < ApplicationController
  before_action :authorize_user, :set_contact
  before_action :authorize_owner, only: [:edit, :update, :destroy]

  def index
    @contacts = current_user.contacts.order(:created_at)
  end

  def show
  end

  def new
    @contact = current_user.contacts.new

    render :form
  end

  def create
    @contact = current_user.contacts.new(contact_params)

    if @contact.save
      redirect_to :contacts
    else
      render :form
    end
  end

  def edit
    render :form
  end

  def update
    if @contact.update(contact_params)
      redirect_to :contacts
    else
      render :form
    end
  end

  def destroy
    if @contact.destroy
      redirect_to contacts_path
    else
      redirect_to @contact, alert: "Failed to delete contact: #{@contact.errors.full_messages.join("\n")}"
    end
  end

  private

  def authorize_owner
    return if @contact.user == current_user

    redirect_to @contact, alert: "You cannot make changes to this contact."
  end

  def set_contact
    @contact = Contact.find(params[:id]) if params[:id].present?
  end

  def contact_params
    params.require(:contact).permit(
      :address,
      :lat,
      :lng,
      :name,
      :nickname,
      :phone,
    )
  end
end
