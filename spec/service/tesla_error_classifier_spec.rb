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

  # The exception class is the one fact the alert always has, and each one
  # rules out a different set of causes.
  describe "#proxy_verdict" do
    it "gives refused, unreachable and timed-out connections each their own verdict" do
      verdicts = [Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ETIMEDOUT].map { |klass|
        described_class.proxy_verdict(klass.new)
      }

      expect(verdicts).to all(be_present)
      expect(verdicts.uniq.length).to eq(3)
    end

    it "resolves through the ancestry so subclasses still read straight" do
      subclass = Class.new(SocketError)
      expect(described_class.proxy_verdict(subclass.new)).to match_array(described_class::PROXY_VERDICTS["SocketError"])
    end

    it "returns nil for a class it doesn't map" do
      expect(described_class.proxy_verdict(StandardError.new)).to be_nil
    end
  end

  describe "#slack_message" do
    let(:probe_result) {
      {
        ip:          "97.117.17.133",
        ok:          false,
        failed_at:   :tcp,
        layers:      [
          { key: :config, label: "local_ip is configured", ok: true, fatal: true, detail: "97.117.17.133" },
          { key: :tcp, label: "port 3142 accepts a TCP connection", ok: false, fatal: true, detail: "No route to host" },
        ],
        remediation: ["Router port-forward / DMZ for 3142 must target the Mac's CURRENT LAN IP."],
      }
    }

    before { allow(ProxyRequest).to receive(:probe).and_return(probe_result) }

    it "probes a proxy failure live, carrying where it happened and the mute link" do
      msg = described_class.slack_message(
        Errno::EHOSTUNREACH.new,
        where:       "proxy_command:flash_lights",
        toggle_link: "<link|Mute>",
      )

      expect(ProxyRequest).to have_received(:probe)
      expect(msg).to include("proxy_command:flash_lights", "<link|Mute>", "97.117.17.133", "port 3142")
    end

    # The probe is a best-effort extra. Losing it must never cost us the alert
    # that carried it.
    it "still renders the alert when the probe itself blows up" do
      allow(ProxyRequest).to receive(:probe).and_raise(Errno::EACCES, "denied")

      expect(described_class.slack_message(Errno::EHOSTUNREACH.new, where: "x", toggle_link: "<y>")).to include("<y>")
    end

    it "does not probe for non-proxy categories" do
      exc = RestClient::Unauthorized.new(instance_double(RestClient::Response, code: 401, body: ""))
      msg = described_class.slack_message(exc, where: "Refresh Error", toggle_link: "<link|Mute>")

      expect(msg).to include("Refresh Error", "<link|Mute>")
      expect(ProxyRequest).not_to have_received(:probe)
    end
  end
end
