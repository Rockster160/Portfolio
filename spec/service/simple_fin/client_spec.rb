require "rails_helper"

# The access URL embeds credentials, the query is presence-flag based, and a
# 200 can still carry per-institution failures. Those three are what the
# examples below pin down.
RSpec.describe SimpleFin::Client do
  let(:access_url) { "https://user1:pass1@bridge.simplefin.org/simplefin" }
  let(:endpoint) { "https://bridge.simplefin.org/simplefin/accounts" }
  let(:payload) {
    {
      errlist:     [],
      connections: [],
      accounts:    [
        {
          id:             "acc_1",
          name:           "PREMIER PLUS CKG (2363)",
          conn_id:        "conn_1",
          currency:       "USD",
          balance:        "1234.56",
          "balance-date": 1_754_800_000,
        },
      ],
    }.to_json
  }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("PORTFOLIO_SIMPLEFIN_ACCESS_URL").and_return(access_url)
  end

  def capture_request_path
    captured = nil
    build = ::Net::HTTP::Get.method(:new)
    allow(::Net::HTTP::Get).to receive(:new) { |path, *rest|
      captured = path.to_s
      build.call(path, *rest)
    }
    yield
    captured
  end

  def stub_accounts(query: hash_including({}), body: payload, status: 200)
    stub_request(:get, endpoint).with(query: query).to_return(
      status: status, body: body, headers: { "Content-Type" => "application/json" },
    )
  end

  describe ".accounts" do
    it "authenticates with the credentials embedded in the access URL" do
      request = stub_accounts.with(basic_auth: ["user1", "pass1"])

      described_class.accounts
      expect(request).to have_been_requested
    end

    it "returns the parsed account set" do
      stub_accounts

      result = described_class.accounts
      expect(result["accounts"].first["balance"]).to eq("1234.56")
      expect(result["accounts"].first["name"]).to eq("PREMIER PLUS CKG (2363)")
    end

    it "asks for v2 so errors come back as errlist" do
      request = stub_accounts(query: hash_including("version" => "2"))

      described_class.accounts
      expect(request).to have_been_requested
    end

    it "surfaces errlist rather than swallowing a partial refresh" do
      stub_accounts(body: {
        errlist:  [{ id: "err_1", message: "Chase needs reauthentication" }],
        accounts: [],
      }.to_json)

      result = described_class.accounts
      expect(result["errlist"].first["message"]).to eq("Chase needs reauthentication")
    end

    context "when building query parameters" do
      it "sends balances-only as a presence flag" do
        request = stub_accounts(query: hash_including("balances-only" => "1"))

        described_class.accounts(balances_only: true)
        expect(request).to have_been_requested
      end

      it "omits balances-only entirely when not asked for" do
        stub_accounts

        described_class.accounts(balances_only: false)
        expect(a_request(:get, endpoint).with(query: hash_including("balances-only" => "0")))
          .not_to have_been_made
      end

      # Captured before WebMock sees it. WebMock normalises `request.uri` —
      # params get sorted and duplicate keys collapse to the last value — so
      # asserting through it would hide the very thing being tested.
      it "sends a repeated account parameter for each id" do
        stub_accounts

        path = capture_request_path {
          described_class.accounts(account_ids: ["acc_1", "acc_2"])
        }
        expect(path).to include("account=acc_1", "account=acc_2")
      end

      it "sends dates as unix timestamps" do
        start_date = Time.utc(2026, 7, 1)
        request = stub_accounts(query: hash_including("start-date" => start_date.to_i.to_s))

        described_class.accounts(start_date: start_date, end_date: Time.utc(2026, 7, 20))
        expect(request).to have_been_requested
      end
    end

    it "refuses a range wider than the documented 90-day cap" do
      expect {
        described_class.accounts(start_date: Time.utc(2026, 1, 1), end_date: Time.utc(2026, 6, 1))
      }.to raise_error(SimpleFin::Client::RangeTooWide)
    end

    it "raises on a non-success response instead of returning nil" do
      stub_accounts(status: 500, body: "upstream exploded")

      expect { described_class.accounts }.to raise_error(SimpleFin::Client::Error, /500/)
    end

    it "raises when the access URL is not configured" do
      allow(ENV).to receive(:[]).with("PORTFOLIO_SIMPLEFIN_ACCESS_URL").and_return(nil)

      expect { described_class.accounts }.to raise_error(SimpleFin::Client::NotConfigured)
    end
  end

  describe ".configured?" do
    it "is true when the access URL is present" do
      expect(described_class).to be_configured
    end

    it "is false when it is missing" do
      allow(ENV).to receive(:[]).with("PORTFOLIO_SIMPLEFIN_ACCESS_URL").and_return(nil)
      expect(described_class).not_to be_configured
    end
  end
end
