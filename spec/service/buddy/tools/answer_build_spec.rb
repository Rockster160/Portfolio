require "rails_helper"

RSpec.describe "answer_build" do
  before { ActiveStorage::Current.url_options = { host: "example.com", protocol: "https" } }
  after  { ActiveStorage::Current.url_options = nil }

  let(:user)  { User.me }
  let(:tool)  { Buddy::Tools[:answer_build] }
  let(:ctx)   { Buddy::ToolContext.new(user) }
  let!(:build) {
    FeatureBuild.create!(
      user:     user,
      status:   :running,
      title:    "dark mode",
      request:  "add dark mode",
      question: "Dark by default?",
      asked_at: Time.current,
    )
  }

  def run(payload)
    confirm  = tool[:confirm].call(payload, ctx)
    resolved = payload.merge(confirm[:resolved] || {})
    tool[:receipt].call(tool[:execute].call(resolved, ctx), ctx)
  end

  it "types the answer into the build's session" do
    sent = stub_request(:post, %r{/byte/builder\z}).with(
      body: hash_including("action" => "message", "build_id" => build.id, "text" => "yes"),
    ).to_return(status: 200, body: "{}")

    expect(run({ id: build.id, answer: "yes" })).to eq("Sent to dark mode 🛠️")
    expect(sent).to have_been_requested
    expect(build.reload.question).to be_nil
  end

  it "sends the images on the message being answered along with it" do
    convo = user.byte_conversations.create!(name: :Buddy, mode: :buddy)
    message = convo.byte_messages.create!(user: user, direction: :outbound, state: :sent, body: "like this")
    message.files.attach(io: StringIO.new("png"), filename: "mock.png", content_type: "image/png")
    sent = stub_request(:post, %r{/byte/builder\z}).with { |request|
      attachments = JSON.parse(request.body)["attachments"].to_a
      attachments.map { |image| image["filename"] } == ["mock.png"] && attachments.first["url"].present?
    }.to_return(status: 200, body: "{}")
    in_thread = Buddy::ToolContext.new(user, conversation: convo)

    confirm = tool[:confirm].call({ id: build.id, answer: "like this" }, in_thread)
    tool[:execute].call({ answer: "like this" }.merge(confirm[:resolved]), in_thread)

    expect(sent).to have_been_requested
  end

  it "sends no images when the message being answered has none" do
    convo = user.byte_conversations.create!(name: :Buddy, mode: :buddy)
    convo.byte_messages.create!(user: user, direction: :outbound, state: :sent, body: "yes")
    in_thread = Buddy::ToolContext.new(user, conversation: convo)

    expect(tool[:confirm].call({ id: build.id, answer: "yes" }, in_thread)[:resolved]).not_to have_key(:message_id)
  end

  it "refuses a build that isn't asking anything" do
    build.update!(question: nil, asked_at: nil)

    expect { run({ id: build.id, answer: "yes" }) }.to raise_error(/no build is asking/)
  end

  it "says so when the Mini doesn't take it" do
    stub_request(:post, %r{/byte/builder\z}).to_return(status: 502)

    expect { run({ id: build.id, answer: "yes" }) }.to raise_error(/couldn't reach the Mini/)
    expect(build.reload.question).to eq("Dark by default?")
  end

  describe "the turn's glance" do
    let(:turn) {
      Buddy::GPT::Turn.allocate.tap { |turn| turn.instance_variable_set(:@user, user) }
    }

    def holding_mac(held)
      allow(Buddy::Features).to receive(:enabled?).and_call_original
      allow(Buddy::Features).to receive(:enabled?).with(user, :mac).and_return(held)
    end

    it "carries the build while it's asking" do
      holding_mac(true)

      expect(turn.send(:builds_asking)).to eq([{ id: build.id, title: "dark mode", asked: "Dark by default?" }])
    end

    it "leaves it out for anyone without the Mac" do
      holding_mac(false)

      expect(turn.send(:builds_asking)).to be_nil
    end
  end
end
