class EmailsController < ApplicationController
  before_action :authorize_admin

  def index
    # FIXME: Filter this by user unless admin?
    @emails_received = Email.not_archived.inbound.order_chrono.page(params[:emails_received_page]).per(params[:emails_received_per] || 10)
    @emails_sent = Email.not_archived.outbound.order_chrono.page(params[:emails_sent_page]).per(params[:emails_sent_per] || 10)
    @failed_to_parse = Email.not_archived.failed.order_chrono.page(params[:emails_failed_page]).per(params[:emails_failed_per] || 10)
  end

  def show
    @email = Email.find(params[:id])
    @email.read
  end

  def new
    @email = current_user.sent_emails.new(email_params)
    @email.from_user ||= current_user.email.in?(Email.registered_domains) ? current_user.email : "#{(current_user.username.presence || 'contact')}@ardesian.com"
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
    @email = Email.find(params[:id])
    @email.update(update_params)
    redirect_to emails_path
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
