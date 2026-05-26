# Wraps the events.watch / channels.stop dance for a single agenda.
# `start!` registers a new push channel and persists its identity on the
# agenda so the webhook receiver can look the agenda up by X-Goog-Channel-Id.
class GoogleCalendar::WatchManager
  # Channels POST here. The token below is verified server-side as a defense
  # against spoofed deliveries.
  WEBHOOK_PATH = "/webhooks/google_calendar".freeze

  attr_reader :agenda, :api

  def initialize(agenda)
    @agenda = agenda
    @api = ::Oauth::GoogleApi.new(agenda.user)
  end

  def self.start!(agenda)
    new(agenda).start!
  end

  def self.stop!(agenda)
    new(agenda).stop!
  end

  def start!
    # Stop any in-flight channel first — otherwise we leak channels on the
    # Google side without a way to remove them.
    stop! if @agenda.watch_channel_id.present?

    channel_id = SecureRandom.uuid
    response = @api.watch_events(
      @agenda.external_id,
      channel_id: channel_id,
      address:    callback_url,
      token:      channel_token,
    )
    return unless response.is_a?(::Hash)

    expiration_ms = response[:expiration].to_i
    @agenda.update!(
      watch_channel_id:  channel_id,
      watch_resource_id: response[:resourceId],
      watch_expires_at:  expiration_ms.positive? ? ::Time.zone.at(expiration_ms / 1000.0) : nil,
      watch_failed_at:   nil,
    )
    response
  rescue ::RestClient::Forbidden, ::RestClient::BadRequest => e
    # Google denies push for some resource types (holiday calendars, certain
    # shared/read-only calendars). Record the failure so the renewal worker
    # backs off — caller doesn't need to know the difference between this
    # and a transient error; either way, push isn't running and poll-fallback
    # carries the load.
    ::Rails.logger.warn(
      "[GoogleCalendar::WatchManager] watch denied agenda=#{@agenda.id} err=#{e.class}",
    )
    @agenda.update!(watch_failed_at: ::Time.current)
    nil
  end

  def stop!
    return unless @agenda.watch_channel_id.present? && @agenda.watch_resource_id.present?

    begin
      @api.stop_watch(
        channel_id:  @agenda.watch_channel_id,
        resource_id: @agenda.watch_resource_id,
      )
    rescue ::RestClient::NotFound, ::RestClient::Gone
      # Channel was already cleaned up server-side — nothing to undo.
    end

    @agenda.update!(watch_channel_id: nil, watch_resource_id: nil, watch_expires_at: nil)
  end

  # Token is verifiable from the webhook handler: rederive it and compare.
  # Bound to the agenda id + Rails secret so a third party can't forge a
  # delivery that matches one of our channels.
  def channel_token
    self.class.token_for(@agenda)
  end

  def self.token_for(agenda)
    ::OpenSSL::HMAC.hexdigest(
      "SHA256",
      ::Rails.application.secret_key_base,
      "google_calendar:agenda:#{agenda.id}",
    )
  end

  private

  def callback_url
    base = ENV.fetch("PORTFOLIO_PUBLIC_HOST", "https://ardesian.com").sub(/\/$/, "")
    "#{base}#{WEBHOOK_PATH}"
  end
end
