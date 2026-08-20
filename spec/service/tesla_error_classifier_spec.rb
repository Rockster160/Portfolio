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

  # The exception class is the one fact the alert always has, and it eliminates
  # most of the candidate causes on its own. These examples pin the eliminations
  # rather than the prose, so rewording stays cheap but the logic can't drift.
  describe "#proxy_verdict" do
    it "says a refused connection means the relay, not the Mac" do
      lines = described_class.proxy_verdict(Errno::ECONNREFUSED.new).join(" ")
      expect(lines).to match(/Nothing is listening/)
      expect(lines).to match(/Mac itself is fine/)
    end

    # A sleeping Mac CAN produce this: the router fails to ARP it and returns
    # host-unreachable itself. What it rules out is a crashed relay on a live
    # Mac, which refuses the connection rather than going unreachable.
    it "keeps both unreachable causes open on EHOSTUNREACH but rules out a refusal" do
      lines = described_class.proxy_verdict(Errno::EHOSTUNREACH.new).join(" ")
      expect(lines).to match(/no route to host/i)
      expect(lines).to match(/dead port-forward/)
      expect(lines).to match(/asleep or off/)
      expect(lines).to match(/Rules OUT a crashed relay on a \*live\* Mac/)
    end

    it "points a timeout at the router or a powered-off Mac" do
      expect(described_class.proxy_verdict(Errno::ETIMEDOUT.new).join(" ")).to match(/silently dropped/)
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
          { key: :ping, label: "host answers ICMP ping (informational)", ok: false, fatal: false, detail: "no ICMP reply" },
          { key: :tcp, label: "port 3142 accepts a TCP connection", ok: false, fatal: true, detail: "Errno::EHOSTUNREACH: No route to host" },
        ],
        remediation: ["Router port-forward / DMZ for 3142 must target the Mac's CURRENT LAN IP."],
      }
    }

    before { allow(ProxyRequest).to receive(:probe).and_return(probe_result) }

    it "leads with what the error class proves instead of a generic checklist" do
      msg = described_class.slack_message(
        Errno::EHOSTUNREACH.new,
        where:       "proxy_command:flash_lights",
        toggle_link: "<link|Mute>",
      )
      expect(msg).to include("home Mac proxies")
      expect(msg).to include("What the error class proves")
      expect(msg).to include("Rules OUT")
      expect(msg).to include("proxy_command:flash_lights")
      expect(msg).to include("<link|Mute>")
    end

    it "embeds the live probe, naming the layer that broke" do
      msg = described_class.slack_message(Errno::EHOSTUNREACH.new, where: "x", toggle_link: "y")
      expect(msg).to include("Live probe — 97.117.17.133:3142")
      expect(msg).to include("✓ local_ip is configured")
      expect(msg).to include("✗ port 3142 accepts a TCP connection")
      expect(msg).to include("Fix (broken at `tcp`)")
      expect(msg).to include("must target the Mac's CURRENT LAN IP")
    end

    # A non-fatal layer failing is a hint, not the verdict. Marking it the same
    # as the fatal one is how a filtered ping got read as the cause.
    it "marks a non-fatal layer distinctly from the fatal one" do
      msg = described_class.slack_message(Errno::EHOSTUNREACH.new, where: "x", toggle_link: "y")
      expect(msg).to include("! host answers ICMP ping")
    end

    it "reports a healthy probe as the break being past the relay" do
      allow(ProxyRequest).to receive(:probe).and_return(probe_result.merge(ok: true, failed_at: nil))
      msg = described_class.slack_message(Errno::EHOSTUNREACH.new, where: "x", toggle_link: "y")
      expect(msg).to include("All layers healthy")
    end

    # The probe is a best-effort extra. Losing it must never cost us the alert
    # that carried it, so the failure is reported inline and the message stands.
    it "still renders the alert when the probe itself blows up" do
      allow(ProxyRequest).to receive(:probe).and_raise(Errno::EACCES, "denied")
      msg = described_class.slack_message(Errno::EHOSTUNREACH.new, where: "x", toggle_link: "y")
      expect(msg).to include("Live probe failed to run")
      expect(msg).to include("home Mac proxies")
      expect(msg).to include("y")
    end

    it "does not probe for non-proxy categories" do
      exc = RestClient::Unauthorized.new(instance_double(RestClient::Response, code: 401, body: ""))
      msg = described_class.slack_message(exc, where: "Refresh Error", toggle_link: "<link|Mute>")
      expect(msg).to include("Oauth::TeslaApi.me.auth_url")
      expect(msg).not_to include("Live probe")
      expect(ProxyRequest).not_to have_received(:probe)
    end
  end
end
