# Runs when the relay checks in while prod still believes the proxy is
# unreachable. The check-in alone proves only that the Mac can reach US —
# outbound. The probe is what proves the INBOUND path is back, and inbound is
# the half that was broken, so recovery is gated on the probe rather than on
# the check-in that triggered it.
class TeslaProxyRecoveryWorker
  include Sidekiq::Worker

  # A failed recovery is not worth retrying on Sidekiq's schedule: the next
  # relay check-in re-triggers this within a couple of minutes anyway, and by
  # then the state it reads may have changed.
  sidekiq_options retry: false

  def perform
    return unless ::DataStorage[:tesla_proxy_unreachable]
    return if ::TeslaSwitch.disabled?
    return unless ::ProxyRequest.probe[:ok]

    # The probe just walked the whole path end-to-end, so "unreachable" is
    # false whatever happens next. Clearing it here also stops this worker
    # firing on every check-in while a purely auth-side problem gets sorted.
    ::TeslaCommand.proxy_unreachable!(false)

    refresh_tesla
  end

  # A token that expires mid-outage cannot be refreshed while the relay is
  # unreachable, because the exchange itself routes through that relay
  # (Oauth::TeslaApi#proxy_refresh). The connection coming back is precisely
  # when the retry belongs.
  def refresh_tesla
    ::TeslaControl.me.refresh
    ::SlackNotifier.notify(
      ":satellite: *Tesla home proxy recovered* — reachable end-to-end at " \
      "`#{::DataStorage[:local_ip]}:#{::ProxyRequest::PROXY_PORT}`, token refreshed.",
    )
  rescue StandardError
    # TeslaControl#refresh already posted the classified failure to Slack and
    # re-raised. Saying it a second time here would just duplicate that alert.
    nil
  end
end
