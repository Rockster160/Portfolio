class GoogleApi < Oauth
  # OAUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"
  # TOKEN_URL = "https://oauth2.googleapis.com/token"
  # PROJECT_ID = ENV.fetch("PORTFOLIO_GCP_PROJECT_ID")
  # CLIENT_ID = ENV.fetch("PORTFOLIO_GCP_CLIENT_ID")
  # CLIENT_SECRET = ENV.fetch("PORTFOLIO_GCP_CLIENT_SECRET")
  # REDIRECT_URI = "https://ardesian.com"
  # STORAGE_KEY = :google_api
  constants(
    OAUTH_URL: "https://accounts.google.com/o/oauth2/v2/auth",
    TOKEN_URL: "https://oauth2.googleapis.com/token",
    PROJECT_ID: ENV.fetch("PORTFOLIO_GCP_PROJECT_ID"),
    CLIENT_ID: ENV.fetch("PORTFOLIO_GCP_CLIENT_ID"),
    CLIENT_SECRET: ENV.fetch("PORTFOLIO_GCP_CLIENT_SECRET"),
    REDIRECT_URI: "https://ardesian.com",
    STORAGE_KEY: :google_api,
  )

  def self.next10
    # Fetching the user's next 10 events
    calendar_id = "primary"
    response = RestClient.get("https://www.googleapis.com/calendar/v3/calendars/" +
      "#{calendar_id}/events?maxResults=10&singleEvents=true&orderBy=startTime&" +
      "timeMin=#{Time.now.utc.iso8601}", { Authorization: "Bearer #{DataStorage["#{STORAGE_KEY}_access_token"]}" })

    puts "\e[36m[LOGIT] | #{response.body.presence || response}\e[0m"
    json = JSON.parse(response.body, symbolize_names: true)
    events = json[:items]

    puts "Upcoming events:"
    if events.empty?
      puts "No events found"
    else
      events.each do |event|
        start = event.dig(:start, :dateTime) || event.dig(:start, :date)
        puts "- #{event[:summary]} (#{start})"
      end
    end
  end
end
