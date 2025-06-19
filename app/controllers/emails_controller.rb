class EmailsController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authorize_admin

  def index
    @emails = current_user.emails.ordered
    @emails = @emails.query(params[:q])
    @emails = @emails.page(params[:page]).per(params[:per] || 10)
  end

  def show
    @email = current_user.emails.find(params[:id])
    @email.read!
  end

  def new
    @email = current_user.sent_emails.new(email_params)
    @email.from_user ||= current_user.email.in?(::Email.registered_domains) ? current_user.email : "#{(current_user.username.presence || 'contact')}@ardesian.com"
  end

  def create
    @email = current_user.sent_emails.new(email_params)
    @email.set_send_values

    if @email.errors.none? && @email.save
      @email.deliver!
      redirect_to emails_path
    else
      render :new
    end
  end

  def update
    @email = ::Email.find(params[:id])
    @email.update(update_params)

    respond_to do |format|
      format.html { redirect_to emails_path }
      format.json { render json: @email }
    end
  end

  private

  def update_params
    params.require(:email).permit(
      :archived,
      :read,
      :html_body,
    )
  end

  def email_params
    params.fetch(:email, {}).permit(:html_body, :from_user, :from_domain, :to, :subject, tempfiles: [])
  end

end
