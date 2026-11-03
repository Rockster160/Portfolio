require "rails_helper"

RSpec.describe AuthHelper, type: :helper do
  # Read-side sanitizing: a session can carry a bad forwarding_url from before
  # store-side filtering existed.
  describe "#previous_url" do
    it "returns a stored page path, query string included" do
      ["/api_keys", "/agenda?date=2026-08-11"].each { |path|
        session[:forwarding_url] = path
        expect(helper.previous_url).to eq(path)
      }
    end

    it "discards .json, off-site and protocol-relative destinations" do
      [
        "/chores/icons.json",
        "/api_keys.json?page=2",
        "https://example.com/phish",
        "//example.com/phish",
      ].each { |path|
        session[:forwarding_url] = path
        expect(helper.previous_url).to eq(lists_path), path
      }
    end

    it "prefers the caller's fallback over /lists" do
      session[:forwarding_url] = "/chores/icons.json"
      expect(helper.previous_url(account_path)).to eq(account_path)
    end
  end
end
