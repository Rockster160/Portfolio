require "rails_helper"

RSpec.describe TeslaErrorClassifier do
  describe "#classify" do
    it "maps EHOSTUNREACH to :proxy_unreachable" do
      expect(described_class.classify(Errno::EHOSTUNREACH.new)).to eq(:proxy_unreachable)
    end

    it "maps RestClient::Unauthorized to :auth_refresh_failed" do
      exc = RestClient::Unauthorized.new(instance_double(RestClient::Response, code: 401, body: ""))
      expect(described_class.classify(exc)).to eq(:auth_refresh_failed)
    end

    it "maps RestClient::BadRequest to :bad_request" do
      exc = RestClient::BadRequest.new(instance_double(RestClient::Response, code: 400, body: ""))
      expect(described_class.classify(exc)).to eq(:bad_request)
    end

    it "maps a 503 to :tesla_5xx" do
      resp = instance_double(RestClient::Response, code: 503, body: "")
      exc = RestClient::ServiceUnavailable.new(resp)
      allow(exc).to receive(:response).and_return(resp)
      expect(described_class.classify(exc)).to eq(:tesla_5xx)
    end

    it "maps 500 'vehicle is offline or asleep' body to :vehicle_asleep" do
      resp = instance_double(RestClient::Response, code: 500, body: %({"error":"vehicle unavailable: vehicle is offline or asleep"}))
      exc = RestClient::InternalServerError.new(resp)
      allow(exc).to receive(:response).and_return(resp)
      expect(described_class.classify(exc)).to eq(:vehicle_asleep)
    end

    it "falls back to :unknown for unrecognized errors" do
      expect(described_class.classify(StandardError.new("boom"))).to eq(:unknown)
    end
  end

  describe "#slack_message" do
    it "renders a proxy_unreachable message including kickstart commands" do
      msg = described_class.slack_message(
        Errno::EHOSTUNREACH.new,
        where:       "proxy_command:flash_lights",
        toggle_link: "<link|Mute>",
      )
      expect(msg).to include("home Mac proxies")
      expect(msg).to include("launchctl kickstart")
      expect(msg).to include("proxy_command:flash_lights")
      expect(msg).to include("<link|Mute>")
    end

    it "renders an auth_refresh_failed message including auth_url one-liner" do
      exc = RestClient::Unauthorized.new(instance_double(RestClient::Response, code: 401, body: ""))
      msg = described_class.slack_message(exc, where: "Refresh Error", toggle_link: "<link|Mute>")
      expect(msg).to include("Oauth::TeslaApi.me.auth_url")
    end
  end
end
