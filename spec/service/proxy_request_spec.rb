require "rails_helper"

RSpec.describe ProxyRequest do
  subject(:diag) { ProxyRequest.new }

  before do
    allow(DataStorage).to receive(:[]).with(:local_ip).and_return("97.117.17.133")
    # Happy-path stubs; individual examples override the layer under test.
    allow(diag).to receive_messages(
      ping_host: true,
      tcp_error: nil,
      http_test: %({"success":true}),
    )
    allow(LocalIpManager).to receive(:last_seen_at).and_return(2.minutes.ago)
    allow(ProxyRequest).to receive(:relay_last_seen_at).and_return(2.minutes.ago)
  end

  describe "#probe" do
    it "reports every layer healthy when all checks pass" do
      result = diag.probe
      expect(result[:ok]).to be(true)
      expect(result[:failed_at]).to be_nil
      expect(result[:layers].pluck(:key)).to eq([:house, :relay, :config, :ping, :tcp, :http])
    end

    # ICMP is filtered by plenty of routers. Treating it as fatal aborted the
    # walk here and blamed the pre-router path while the port was the real
    # story, which is exactly how the alert kept pointing at the wrong cause.
    it "keeps walking past a failed ping and still reaches the relay" do
      allow(diag).to receive(:ping_host).and_return(false)
      result = diag.probe
      expect(result[:ok]).to be(true)
      expect(result[:failed_at]).to be_nil
      expect(result[:layers].find { |l| l[:key] == :ping }).to include(ok: false, fatal: false)
    end

    it "stops at :config when local_ip is unset" do
      allow(DataStorage).to receive(:[]).with(:local_ip).and_return(nil)
      result = diag.probe
      expect(result[:failed_at]).to eq(:config)
      expect(result[:layers].pluck(:key)).to eq([:house, :relay, :config])
    end

    it "blames the dead port-forward on EHOSTUNREACH" do
      allow(diag).to receive(:tcp_error).and_return(Errno::EHOSTUNREACH.new("No route to host"))
      result = diag.probe
      expect(result[:failed_at]).to eq(:tcp)
      expect(result[:remediation].join("\n")).to match(/no device currently holds|dead port-forward/)
    end

    it "blames the relay on ECONNREFUSED" do
      allow(diag).to receive(:tcp_error).and_return(Errno::ECONNREFUSED.new("Connection refused"))
      result = diag.probe
      expect(result[:remediation].join("\n")).to match(/Ruby relay is down/)
      expect(result[:remediation].join("\n")).to match(%r{kickstart -k gui/\$UID/com\.ardesian\.tesla-ruby-relay})
    end

    it "blames filtering on ETIMEDOUT" do
      allow(diag).to receive(:tcp_error).and_return(Errno::ETIMEDOUT.new("timed out"))
      result = diag.probe
      expect(result[:failed_at]).to eq(:tcp)
      expect(result[:remediation].join("\n")).to match(/silently dropped|filtering/)
    end

    # A dead port on a host that still answers ping is a forwarding problem.
    # Silence at BOTH layers is the only case where the address itself is worth
    # doubting, so the stale-IP advice is gated on that rather than always-on.
    it "omits the stale-IP check while the host still answers ICMP" do
      allow(diag).to receive(:tcp_error).and_return(Errno::EHOSTUNREACH.new("No route to host"))
      expect(diag.probe[:remediation].join("\n")).not_to match(/curl ifconfig\.me/)
    end

    it "adds the stale-IP check once ICMP goes unanswered too" do
      allow(diag).to receive_messages(
        ping_host: false,
        tcp_error: Errno::EHOSTUNREACH.new("No route to host"),
      )
      expect(diag.probe[:remediation].join("\n")).to match(/curl ifconfig\.me/)
    end

    # The check-ins answer the one question the network walk cannot: an offline
    # house and a mis-forwarded router fail every network layer alike.
    it "reports both check-ins without failing the walk" do
      result = diag.probe
      expect(result[:ok]).to be(true)
      expect(result[:layers].find { |l| l[:key] == :house }).to include(ok: true, fatal: false)
      expect(result[:layers].find { |l| l[:key] == :relay }).to include(ok: true, fatal: false)
    end

    it "flags a stale check-in but still walks the network" do
      allow(LocalIpManager).to receive(:last_seen_at).and_return(3.hours.ago)
      result = diag.probe
      expect(result[:ok]).to be(true)
      expect(result[:layers].find { |l| l[:key] == :house }[:detail]).to match(/3h ago — stale/)
    end

    it "says so when no check-in was ever recorded" do
      allow(ProxyRequest).to receive(:relay_last_seen_at).and_return(nil)
      detail = diag.probe[:layers].find { |l| l[:key] == :relay }[:detail]
      expect(detail).to match(/no relay heartbeat ever recorded/)
    end

    # The PAIR is the discriminator. These four cases are the whole point of
    # the relay reporting separately from the household ping.
    context "when the network path is broken" do
      before { allow(diag).to receive(:tcp_error).and_return(Errno::EHOSTUNREACH.new("No route to host")) }

      it "blames the Mac when the house checks in and the relay doesn't" do
        allow(ProxyRequest).to receive(:relay_last_seen_at).and_return(3.hours.ago)
        expect(diag.probe[:remediation].first).to match(/relay is NOT/)
        expect(diag.probe[:remediation].join("\n")).to match(/asleep\/off, or the relay process died/)
      end

      it "blames the whole network when neither checks in" do
        allow(LocalIpManager).to receive(:last_seen_at).and_return(3.hours.ago)
        allow(ProxyRequest).to receive(:relay_last_seen_at).and_return(3.hours.ago)
        expect(diag.probe[:remediation].first).to match(/Nothing has checked in/)
      end

      it "clears the Mac but flags the dead pinger when only the house is silent" do
        allow(LocalIpManager).to receive(:last_seen_at).and_return(3.hours.ago)
        remediation = diag.probe[:remediation].join("\n")
        expect(remediation).to match(/proxy Mac is up, so this is not your outage/)
      end

      it "stays on the router while both check-ins are current" do
        expect(diag.probe[:remediation].join("\n")).not_to match(/checked in|checking in/)
      end
    end

    it "stops at :http and blames the app behind the socket when /test is wrong" do
      allow(diag).to receive(:http_test).and_return("ERROR: Errno::ECONNRESET: reset")
      result = diag.probe
      expect(result[:failed_at]).to eq(:http)
      expect(result[:remediation].join("\n")).to match(/kickstart BOTH launchd jobs/i)
    end
  end

  # `diagnose` narrates to stdout, and every example below reads that narration
  # through RSpec's `output` matcher. A helper by that name here shadows the
  # matcher - `output(/regex/)` resolved to the helper, which takes no
  # arguments, and all six of those examples died on ArgumentError before
  # reaching an assertion.
  describe "#diagnose" do
    it "narrates a healthy walk and returns the probe result" do
      result = nil
      expect { result = diag.diagnose }.to output(/All layers healthy/).to_stdout
      expect(result[:ok]).to be(true)
    end

    it "narrates the failing layer's remediation" do
      allow(diag).to receive(:tcp_error).and_return(Errno::ECONNREFUSED.new("Connection refused"))
      expect { diag.diagnose }.to output(/What to check.*Ruby relay is down/m).to_stdout
    end

    it "marks a non-fatal ping failure with ! rather than ✗" do
      allow(diag).to receive(:ping_host).and_return(false)
      expect { diag.diagnose }.to output(/!.*ICMP/).to_stdout
    end
  end

  describe ".record_relay_heartbeat!" do
    before do
      # The outer stubs exist for the probe examples; these read the real store.
      allow(DataStorage).to receive(:[]).and_call_original
      allow(ProxyRequest).to receive(:relay_last_seen_at).and_call_original
      DataStorage.where(name: ProxyRequest::RELAY_SEEN_AT_KEY).delete_all
    end

    it "is nil until the relay has ever checked in" do
      expect(ProxyRequest.relay_last_seen_at).to be_nil
    end

    it "round-trips the stamp through DataStorage as a real time" do
      ProxyRequest.record_relay_heartbeat!
      expect(ProxyRequest.relay_last_seen_at).to be_within(5.seconds).of(Time.current)
    end
  end
end
