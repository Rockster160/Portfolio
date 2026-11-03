require "rails_helper"

# read_web_page is a READ that settles inside the turn: the page's text becomes
# the tool output, so the reply is written holding what the page says instead of
# what the link looked like it said.
RSpec.describe "read_web_page tool" do
  let(:user)   { create(:user) }
  let!(:convo) { ByteConversation.create!(user: user, mode: :buddy, name: "Buddy", last_message_at: Time.current) }
  let(:tool)   { Buddy::Tools[:read_web_page] }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(Resolv).to receive(:getaddresses).and_return(["93.184.216.34"])
  end

  def read(payload)
    Buddy::GPT::Turn.resolve_tool(
      tool,
      { call_id: "call_1", name: :read_web_page, arguments: payload },
      user: user, conversation: convo,
    )
  end

  def stub_page(body, type: "text/html")
    stub_request(:get, "https://example.com/events/yappy-hour/")
      .to_return(status: 200, body: body, headers: { "Content-Type" => type })
  end

  it "hands the page's text back in the same turn", :aggregate_failures do
    stub_page(<<~HTML)
      <html><head><title>Yappy Hour | Events</title></head>
        <body><main><h1>Yappy Hour</h1>
          <p>Date: October 8</p>
          <p>Location: Jordan Park, 1060 S 900 W</p>
        </main></body>
      </html>
    HTML

    result = read(url: "https://example.com/events/yappy-hour/")

    expect(result[:status]).to eq(:answered)
    expect(result[:title]).to eq("Yappy Hour | Events")
    expect(result[:text]).to include("Location: Jordan Park, 1060 S 900 W")
  end

  # A failure the model can read out; anything else and it describes a page it
  # never got.
  it "refuses a link on this network without fetching it", :aggregate_failures do
    result = read(url: "http://localhost:8790/jobs/1488")

    expect(result[:status]).to eq("failed")
    expect(result).not_to have_key(:text)
    expect(a_request(:get, /localhost/)).not_to have_been_made
  end

  it "reports a page that isn't there as a failure rather than an empty read", :aggregate_failures do
    stub_request(:get, "https://example.com/events/yappy-hour/").to_return(status: 404, body: "nope")

    result = read(url: "https://example.com/events/yappy-hour/")

    expect(result[:status]).to eq("failed")
    expect(result[:error]).to include("404")
  end
end
