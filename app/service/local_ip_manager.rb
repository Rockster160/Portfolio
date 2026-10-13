module LocalIpManager
  module_function

  SEEN_AT_KEY = :local_ip_seen_at
  # Rack::Attack reads this on every request that falls outside the static home
  # /24, so the current home address lives in Rails.cache (fast) rather than the
  # DB. Refreshed on every check-in; outlives the Mac being briefly offline.
  RACK_SAFELIST_KEY = :rack_attack_home_ip

  def local_ip
    DataStorage[:local_ip]
  end

  # Every check-in stamps the clock, whether or not the address moved. The
  # IP-change path below deliberately writes nothing when the address is
  # unchanged, so a healthy home network and a dead one both used to leave the
  # same trace: none. That made "is anything home?" unanswerable from prod, and
  # kept a sleeping-Mac theory permanently un-eliminable on every proxy alert.
  def record_ping!(ip)
    DataStorage[SEEN_AT_KEY] = Time.current.to_i
    cache_rack_safelist(ip)
    self.local_ip = ip
  end

  def last_seen_at
    raw = DataStorage[SEEN_AT_KEY]
    return nil if raw.blank?

    Time.zone.at(raw.to_i)
  end

  def local_ip=(new_ip)
    old_ip = DataStorage[:local_ip]
    return if new_ip.to_s == "::1"
    return if old_ip.to_s == new_ip.to_s

    if Rails.env.production?
      # ardesian.duckdns.org
      HTTParty.get(
        "https://www.duckdns.org/update?" + {
          domains: "ardesian",
          token:   DataStorage[:duckdns_token],
          ip:      new_ip,
        }.to_query,
      )
    end

    DataStorage[:local_ip] = new_ip
    User.me.caches.set(:local_ip, new_ip)
    whitelist_home_ip!(new_ip, old_ip)

    Jarvis.say("Updated IP Addresses! #{new_ip}")
  end

  # The home router's public IP, as reported by the always-on Mac
  # (webhooks#local_ping only answers for User.me), is an authenticated signal
  # for "this is home" — so the new address is trusted outright. Clear any ban
  # on it and mark it whitelisted at the controller layer, and drop the
  # previous address's whitelist so a reassigned old IP doesn't stay trusted
  # for whoever the ISP hands it to next.
  def whitelist_home_ip!(new_ip, old_ip)
    BannedIp.where(ip: old_ip, whitelisted: true).delete_all if old_ip.present?
    BannedIp.find_or_create_by(ip: new_ip).update!(whitelisted: true)
  end

  def cache_rack_safelist(ip)
    return if ip.to_s == "::1"

    Rails.cache.write(RACK_SAFELIST_KEY, ip.to_s, expires_in: 2.days)
  end
end
