require "rails_helper"

RSpec.describe AuthHelper, type: :helper do
  # Store-side filtering keeps new data URLs out of the session, but sessions
  # already carrying one outlive the fix — they sit in the cookie until the
  # next login. Read-side sanitizing is what stops that one bad landing.
  describe "#previous_url" do
    it "returns a stored page path" do
      session[:forwarding_url] = "/api_keys"
      expect(helper.previous_url).to eq("/api_keys")
    end

    it "keeps the query string" do
      session[:forwarding_url] = "/agenda?date=2026-08-11"
      expect(helper.previous_url).to eq("/agenda?date=2026-08-11")
    end

    it "discards a stored .json path" do
      session[:forwarding_url] = "/chores/icons.json"
      expect(helper.previous_url).to eq(lists_path)
    end

    it "discards a stored .json path carrying a query string" do
      session[:forwarding_url] = "/api_keys.json?page=2"
      expect(helper.previous_url).to eq(lists_path)
    end

    it "discards an off-site destination" do
      session[:forwarding_url] = "https://example.com/phish"
      expect(helper.previous_url).to eq(lists_path)
    end

    it "discards a protocol-relative destination" do
      session[:forwarding_url] = "//example.com/phish"
      expect(helper.previous_url).to eq(lists_path)
    end

    it "prefers the caller's fallback over /lists" do
      session[:forwarding_url] = "/chores/icons.json"
      expect(helper.previous_url(account_path)).to eq(account_path)
    end
  end
end
