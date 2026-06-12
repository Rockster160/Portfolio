require "rails_helper"

RSpec.describe AgendasHelper, type: :helper do
  describe "#location_is_url?" do
    it "matches http and https" do
      expect(helper.location_is_url?("http://example.com")).to be true
      expect(helper.location_is_url?("https://example.com/path")).to be true
      expect(helper.location_is_url?("HTTPS://EXAMPLE.com")).to be true
    end

    it "tolerates surrounding whitespace" do
      expect(helper.location_is_url?("  https://example.com  ")).to be true
    end

    it "rejects addresses and plain names" do
      expect(helper.location_is_url?("123 Main St, Anytown, CA")).to be false
      expect(helper.location_is_url?("Joe's Place")).to be false
      expect(helper.location_is_url?("Mom")).to be false
    end

    it "rejects blank values" do
      expect(helper.location_is_url?(nil)).to be false
      expect(helper.location_is_url?("")).to be false
      expect(helper.location_is_url?("   ")).to be false
    end

    it "does not match a bare domain (must be an http(s) URL)" do
      expect(helper.location_is_url?("example.com")).to be false
    end
  end
end
