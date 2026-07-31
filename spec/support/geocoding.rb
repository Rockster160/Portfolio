# Geocoding is a SIDE EFFECT across most of the agenda suite: saving an item
# with a location enqueues AgendaTravelChainSyncWorker, which resolves that
# location through AddressBook#geocode. Sidekiq runs inline in specs, so a
# dozen examples reached out to Google Maps and died on WebMock — over a travel
# chain not one of them asserts anything about.
#
# Answer ZERO_RESULTS by default. That's the honest "we don't know where that
# is" path: geocode returns nil, the chain resolves to nothing, and the example
# gets on with what it was actually testing. A spec that needs real coordinates
# stubs AddressBook#geocode (or this URL) itself and wins, since WebMock matches
# the most recently declared stub first and example-group hooks run after this.
RSpec.configure do |config|
  config.before do
    stub_request(:get, %r{\Ahttps://maps\.googleapis\.com/maps/api/geocode/json})
      .to_return(
        status:  200,
        body:    { status: "ZERO_RESULTS", results: [] }.to_json,
        headers: { "Content-Type" => "application/json" },
      )
  end
end
