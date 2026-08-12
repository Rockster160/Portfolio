class Rack::Attack
  ### Configure Cache ###

  # If you don't want to use Rails.cache (Rack::Attack's default), then
  # configure it here.
  #
  # Note: The store is only used for throttling (not blocklisting and
  # safelisting). It must implement .increment and .write like
  # ActiveSupport::Cache::Store

  # Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new

  ### Safelist Home Network ###

  # Requests from the home network must never be throttled — the household's
  # PWAs and automations legitimately burst well past the per-IP limit. The
  # residential IP drifts within the /24, so safelist the whole block. A
  # safelist match short-circuits every throttle below before it runs, which
  # the app-level BannedIp/perma_safe whitelisting can't do (that runs in the
  # controller, after Rack::Attack has already returned the 429).
  safelist_ip("97.117.17.0/24")

  ### Throttle Spammy Clients ###

  # If any single client IP is making tons of requests, then they're
  # probably malicious or a poorly-configured scraper. Either way, they
  # don't deserve to hog all of the app server's CPU. Cut them off!
  #
  # Note: If you're serving assets through rack, those requests may be
  # counted by rack-attack and this throttle may be activated too
  # quickly. If so, enable the condition to exclude them from tracking.

  # Throttle all requests by IP (60rpm)
  #
  # Key: "rack::attack:#{Time.now.to_i/:period}:req/ip:#{req.ip}"
  throttle("req/ip", limit: 300, period: 5.minutes, &:ip)

  ### Prevent Brute-Force Login Attacks ###

  # The most common brute-force login attack is a brute-force password
  # attack where an attacker simply tries a large number of emails and
  # passwords to see if any credentials match.
  #
  # Another common method of attack is to use a swarm of computers with
  # different IPs to try brute-forcing a password for a specific account.

  # Throttle POST requests to /login by IP address
  #
  # Key: "rack::attack:#{Time.now.to_i/:period}:logins/ip:#{req.ip}"
  throttle("logins/ip", limit: 5, period: 20.seconds) { |req|
    req.ip if req.path == "/login" && req.post?
  }

  # Throttle POST requests to /login by email param
  #
  # Key: "rack::attack:#{Time.now.to_i/:period}:logins/email:#{normalized_email}"
  #
  # Note: This creates a problem where a malicious user could intentionally
  # throttle logins for another user and force their login requests to be
  # denied, but that's not very common and shouldn't happen to you. (Knock
  # on wood!)
  throttle("logins/email", limit: 5, period: 20.seconds) { |req|
    if req.path == "/login" && req.post?
      # Normalize the email, using the same logic as your authentication process, to
      # protect against rate limit bypasses. Return the normalized email if present, nil otherwise.
      req.params["email"].to_s.downcase.gsub(/\s+/, "").presence
    end
  }

  # Throttle GET requests to /scan/:token by IP address
  #
  # The token itself is 32 urlsafe-base64 characters, so guessing one is not
  # the concern — hammering the endpoint to enumerate is. A real scan is one
  # request, so anything past a handful in a window is not a person scanning.
  #
  # Key: "rack::attack:#{Time.now.to_i/:period}:device_login/ip:#{req.ip}"
  throttle("device_login/ip", limit: 10, period: 1.minute) { |req|
    req.ip if req.path.start_with?("/scan/") && req.get?
  }

  ### Block Cookieless Scrapers ###

  # /recipes/print requires a logged-in session, so any legitimate visitor
  # arrives carrying the Rails session cookie. Distributed scrapers cycling
  # through IPs hit the URL cold with no cookie, so IP throttling can't catch
  # them. Reject cookieless requests to this path in middleware (fast 403,
  # before Rails routing/DB) regardless of source IP.
  blocklist("cookieless recipe print") { |req|
    req.path == "/recipes/print" && req.cookies["_Portfolio_session"].blank?
  }

  ### Custom Throttle Response ###

  # By default, Rack::Attack returns an HTTP 429 for throttled responses,
  # which is just fine.
  #
  # If you want to return 503 so that the attacker might be fooled into
  # believing that they've successfully broken your app (or you just want to
  # customize the response), then uncomment these lines.
  # self.throttled_responder = lambda do |env|
  #  [ 503,  # status
  #    {},   # headers
  #    ['']] # body
  # end
end
