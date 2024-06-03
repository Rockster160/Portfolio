module LocalIpManager
  module_function

  def local_ip=(new_ip)
    old_ip = DataStorage[:local_ip]
    return if new.to_s == "::1"
    return if old_ip.to_s == new_ip.to_s

    DataStorage[:local_ip] = new_ip

    return unless Rails.env.production?

    HTTParty.get(
      "https://www.duckdns.org/update?" + {
        domains: "ardesian,ronaya",
        token: DataStorage[:duckdns_token],
        ip: new_ip
      }.to_query
    )
    Jarvis.say("Updated IP Addresses! #{new_ip}")
  end
end
