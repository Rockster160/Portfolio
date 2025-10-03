module LocalIpManager
  module_function

  def local_ip
    DataStorage[:local_ip]
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

    Jarvis.say("Updated IP Addresses! #{new_ip}")
  end
end
