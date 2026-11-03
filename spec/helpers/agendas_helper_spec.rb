require "rails_helper"

RSpec.describe AgendasHelper, type: :helper do
  describe "#location_is_url?" do
    it "matches only http(s) URLs, tolerating whitespace and case" do
      {
        "http://example.com"       => true,
        "https://example.com/path" => true,
        "HTTPS://EXAMPLE.com"      => true,
        "  https://example.com  "  => true,
        "example.com"              => false,
        "123 Main St, Anytown, CA" => false,
        "Joe's Place"              => false,
        nil                        => false,
        ""                         => false,
        "   "                      => false,
      }.each { |location, expected|
        expect(helper.location_is_url?(location)).to be(expected), location.inspect
      }
    end
  end
end
