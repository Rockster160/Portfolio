require "rails_helper"

# Lock in the fix for: Api.request dispatched GETs to Api.get but only
# looked for query params under opts[:params]. Oauth::Base#request packs
# query params under opts[:payload], so every Google API GET was going
# out without a query string — which caused infinite-pagination loops
# on events.list (pageToken never reached Google, so the same page was
# fetched forever).
RSpec.describe Api do
  describe ".request — GET dispatch" do
    it "forwards `payload` params to Api.get as the query string" do
      expect(described_class).to receive(:get).with(
        "https://example.com/foo",
        { pageToken: "abc", limit: 10 },
        kind_of(Hash),
        hash_including(method: :get),
      )
      described_class.request(
        url:     "https://example.com/foo",
        payload: { pageToken: "abc", limit: 10 },
        headers: {},
        method:  :get,
      )
    end

    it "prefers an explicit :params over :payload when both are present" do
      expect(described_class).to receive(:get).with(
        "https://example.com/foo",
        { explicit: true },
        kind_of(Hash),
        kind_of(Hash),
      )
      described_class.request(
        url:     "https://example.com/foo",
        params:  { explicit: true },
        payload: { ignored: true },
        headers: {},
        method:  :get,
      )
    end
  end
end
