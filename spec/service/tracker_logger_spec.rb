RSpec.describe TrackerLogger do
  let(:request) {
    ActionDispatch::TestRequest.create.tap { |req|
      req.env["REQUEST_METHOD"] = "GET"
      req.env["REQUEST_PATH"] = "/chores/icons/signature"
      req.env["REMOTE_ADDR"] = "203.0.113.30"
      req.env["action_dispatch.request.parameters"] = {}
    }
  }

  before { allow(Rails.env).to receive(:production?).and_return(true) }

  it "stamps the visit count as it stood before this request" do
    described_class.log_request(request)
    expect(LogTracker.last.ip_count).to eq(0)

    described_class.log_request(request)
    expect(LogTracker.last.ip_count).to eq(1)
  end

  it "records the visit against the requesting IP" do
    described_class.log_request(request)

    expect(IpVisit.find_by(ip_address: "203.0.113.30").visit_count).to eq(1)
  end

  # The regression this whole change exists to prevent: deriving ip_count by
  # counting log_trackers was a full scan of a 2.8GB table on every request.
  it "never reads log_trackers to work the count out" do
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload|
      queries << payload[:sql]
    }
    described_class.log_request(request)
    ActiveSupport::Notifications.unsubscribe(subscriber)

    expect(queries.grep(/SELECT COUNT.*FROM "?log_trackers/i)).to be_empty
    expect(queries.grep(/FROM "?log_trackers/i)).to be_empty
  end

  it "skips logging entirely outside production" do
    allow(Rails.env).to receive(:production?).and_return(false)

    expect { described_class.log_request(request) }.not_to change(LogTracker, :count)
    expect(IpVisit.count).to eq(0)
  end
end
