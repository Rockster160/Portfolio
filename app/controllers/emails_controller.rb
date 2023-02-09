class EmailsController < ApplicationController
  skip_before_action :verify_authenticity_token, raise: false
  before_action :authorize_admin

  def index
    # FIXME: Filter this by user unless admin?
    @emails = Email.order_chrono.page(params[:page]).per(params[:per] || 10)

    search = params[:q]&.dup.to_s
    @filters = search.scan(/\w*\:\w+/).each_with_object({}) do |filter, obj|
      # Should include key:"words in quotes"
      search.gsub!(/ ?#{filter} ?/, " ")
      key, val = filter.starts_with?(":") ? [filter[1..-1], nil] : filter.split(":", 2).reverse
      obj[key] = val
    end.with_indifferent_access || {}
    @filters[:search] = search.squish

    @filters.each do |filter, val|
      @emails = (
        case filter.to_sym
        when :sent     then @emails.outbound
        when :read     then @emails.read
        when :unread   then @emails.unread
        when :archived then @emails.archived
        when :failed   then @emails.failed
        when :search   then @emails.search(search)
        else
          @emails
        end
      )
    end
    # Allow passing things like
    # subject:"blah"
    # to filter on specific fields
    # Add buttons to add filters on the FE

    # "all" is a terrible name...
    @emails = @emails.inbound if !@filters.key?(:sent) && !@filters.key?(:all)
    @emails = @emails.not_archived if !@filters.key?(:archived)
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
