class EmailsController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authorize_admin

  # Bodies live on S3, so every row of the JSON digest is a download. Capped
  # hard rather than paginated: the caller wants "what arrived since I last
  # looked", and a window plus a ceiling answers that without a cursor for the
  # two ends to keep in sync.
  DIGEST_MAX = 25

  # What opens in the tab rather than landing in Downloads.
  INLINE_TYPES = [
    "application/pdf",
    "image/png",
    "image/jpeg",
    "image/gif",
    "image/webp",
    "image/svg+xml",
    "text/plain",
  ].freeze

  def index
    @emails = current_user.emails.ordered
    @emails = @emails.query(params[:q])
    @emails = @emails.where(user: current_user).ordered

    # JSON is the local job hunter reading the job-board digests that land here
    # rather than at Gmail — Ladders and anything like it. It asks for a sender
    # and a window and gets the body already parsed, because ParseMail has been
    # decoding this mail correctly for years and a second MIME parser on the
    # other end is one more thing to get wrong.
    return render json: { emails: digest_json } if request.format.json?

    @emails = @emails.page(params[:page]).per(params[:per] || 10)
  end

  def show
    @email = current_user.emails.find(params[:id])
    @email.read!
    @attachments = attachments_for(@email)
  end

  # One file out of the message. The body is rendered in an iframe from
  # `to_html`, which carries the words and nothing else - so a file the mail
  # arrived with was reachable from nowhere at all, with the list view already
  # painting a paperclip to say it was in there.
  #
  # The bytes are read off S3 and handed straight over rather than copied into
  # storage of their own: the mail IS the copy, and a second one would then have
  # a lifetime to manage.
  def attachment
    email = current_user.emails.find(params[:id])
    part = email.attachment_at(params[:index])
    return redirect_to(email_path(email), alert: "That file isn't on this message.") if part.nil?

    send_data(
      part.body.decoded,
      filename:    part.filename.presence || "attachment",
      type:        part.mime_type.presence || "application/octet-stream",
      # Anything the browser can draw opens where it was asked for. Everything
      # else downloads - a calendar invite in particular, which is only any use
      # once it reaches the calendar.
      disposition: INLINE_TYPES.include?(part.mime_type) ? :inline : :attachment,
    )
  end

  def new
    @compose = ::Emails::Compose.new(compose_params)
    @compose.from_domain = ::Email.registered_domains.first if @compose.from_domain.blank?
    @compose.from_user = current_user.username.presence || "contact" if @compose.from_user.blank?
  end

  def create
    @compose = ::Emails::Compose.new(compose_params)
    @compose.user = current_user

    if @compose.deliver!
      redirect_to emails_path, notice: "Email sent."
    else
      render :new, status: :unprocessable_entity
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

  # A blob that cannot be fetched is a page with no file list, never a 500 - the
  # same rule `body_for` keeps for the body itself.
  def attachments_for(email)
    # Off the message rather than off `has_attachments`. The flag is stamped at
    # ingest and the page downloads the mail for its body regardless, so reading
    # the parts costs nothing and a flag that disagrees cannot hide a file.
    email.attachments
  rescue StandardError => e
    Rails.logger.warn("[emails#show] attachments unavailable for #{email.id}: #{e.class}: #{e.message}")
    []
  end

  def digest_json
    scope = filter_by_sender(@emails)
    scope = scope.where(timestamp: params[:hours].to_i.hours.ago..) if params[:hours].present?
    scope = scope.limit([params[:per].to_i, DIGEST_MAX].reject(&:zero?).min || DIGEST_MAX)

    scope.map { |email| digest_row(email) }
  end

  # Substring, not an exact address. A digest arrives from `jobs@my.theladders.com`
  # and the thing worth naming is "theladders.com" — an `@>` containment match
  # on the jsonb would need the whole address and would break the first time
  # they changed a subdomain.
  def filter_by_sender(scope)
    addresses = params[:from].to_s.split(",").map(&:strip).compact_blank
    return scope if addresses.empty?

    clause = addresses.map { "emails.outbound_mailboxes::text ILIKE ?" }.join(" OR ")
    scope.where(clause, *addresses.map { |address| "%#{address}%" })
  end

  def digest_row(email)
    row = {
      id:        email.id,
      subject:   email.subject,
      timestamp: email.timestamp,
      # `json_attributes` casts through SymbolizedJsonFormatter, so these are
      # SYMBOL keys. A string lookup here returns an empty sender and nothing
      # complains about it.
      from:      email.from.pluck(:address).compact_blank.join(", "),
      blurb:     email.blurb,
    }
    return row if params[:body].blank?

    # A body that cannot be fetched is a row without one, never a failed
    # response — one deleted blob must not cost the caller the other 24.
    row.merge(body_for(email))
  end

  def body_for(email)
    { text: email.text_body.to_s, html: email.html_body.to_s }
  rescue StandardError => e
    Rails.logger.warn("[emails#index.json] body unavailable for #{email.id}: #{e.class}: #{e.message}")
    { text: "", html: "", body_error: e.class.to_s }
  end

  def update_params
    params.require(:email).permit(
      :archived,
      :read,
      :html_body,
    )
  end

  def compose_params
    params.fetch(:email, {}).permit(
      :html_body, :from_user, :from_domain, :to, :subject,
      tempfiles: []
    ).to_h
  end
end
