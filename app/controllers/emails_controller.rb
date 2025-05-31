class EmailsController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authorize_admin

  def index
    # FIXME: Filter this by user unless admin?
    @emails = ::Email.ordered.page(params[:page]).per(params[:per] || 10)

    mailboxes = []
    if params[:q].present?
      @emails = @emails.query(params[:q])
      mailboxes = Tokenizing::Node.parse(params[:q]).flatten.filter_map { |node|
        node.is_a?(Hash) && node[:field] == "in" ? node[:conditions] : nil
      }.map(&:to_sym)
    end
    @emails = @emails.inbound unless (mailboxes & [:all, :sent]).any?
    @emails = @emails.not_archived unless (mailboxes & [:all, :archived]).any?
  end

  def show
    @email = ::Email.find(params[:id])
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
