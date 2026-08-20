module LocalIpManager
  module_function

  SEEN_AT_KEY = :local_ip_seen_at

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

    Jarvis.say("Updated IP Addresses! #{new_ip}")
  end
end
