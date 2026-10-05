# The Mac server is the one outside service WebMock lets through. It listens on
# localhost:8788, and `allow_localhost` (kept for Capybara) waves that past the
# net-connect block - so any spec that brushed a ByteLocal call reached the REAL
# Mac with the real secret from .env. Sidekiq runs inline, so creating a Food
# event for User.me fed the live terminal-pet: 10 at a time, every suite run.
#
# Answer "the Mac is asleep" by default. That is the path every caller already
# handles, since the Mac is often off.
#
# A spec that wants a particular answer stubs the same URL in its own before
# hook and wins - WebMock tries the newest stub first.
RSpec.configure do |config|
  config.before {
    stub_request(:any, %r{\A#{Regexp.escape(ByteLocal::DEFAULT_URL)}/}).to_return(
      status:  503,
      body:    JSON.generate({ ok: false, error: "no Mac in specs" }),
      headers: { "Content-Type" => "application/json" },
    )
  }
end
