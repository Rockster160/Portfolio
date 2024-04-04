module LocalIpManager
  module_function

  def local_ip=(new_ip)
    old_ip = DataStorage[:local_ip]
    return if old_ip.to_s == new_ip.to_s

    DataStorage[:local_ip] = new_ip
    HTTParty.get(
      "https://www.duckdns.org/update?" + {
        domains: "ardesian,ronaya",
        token: DataStorage[:duckdns_token],
        ip: new_ip
      }.to_query
    )
  end
end
