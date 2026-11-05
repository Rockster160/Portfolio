require "rails_helper"

RSpec.describe ByteLocal do
  let(:user) { User.me }
  let(:ip)   { "203.0.113.7" }

  before {
    DataStorage[:local_ip] = ip
    stub_const("ENV", ENV.to_h.except("BYTE_LOCAL_URL", "BYTE_LAPTOP_URL"))
  }

  def thread(mode)
    user.byte_conversations.create!(mode: mode, last_message_at: Time.current)
  end

  it "reaches the Mini and the laptop on their own ports of the house IP" do
    expect(described_class.base_url(:mini)).to eq("http://#{ip}:8788")
    expect(described_class.base_url(:laptop)).to eq("http://#{ip}:8789")
  end

  it "lets each Mac's address be set outright" do
    stub_const("ENV", ENV.to_h.merge("BYTE_LAPTOP_URL" => "http://laptop.test:9000"))

    expect(described_class.base_url(:laptop)).to eq("http://laptop.test:9000")
    expect(described_class.base_url(:mini)).to eq("http://#{ip}:8788")
  end

  it "hands a turn to the Mac its thread runs on" do
    mini   = stub_request(:post, "http://#{ip}:8788/byte/incoming").to_return(status: 202)
    laptop = stub_request(:post, "http://#{ip}:8789/byte/incoming").to_return(status: 202)

    [:claude, :bash].each { |mode|
      convo   = thread(mode)
      message = convo.byte_messages.create!(user: user, direction: :outbound, body: "hi")
      described_class.deliver(message, conversation: convo)
    }

    expect(mini).to have_been_requested.once
    expect(laptop).to have_been_requested.once
  end

  it "reports whether a Mac was there to take a sync" do
    stub_request(:post, "http://#{ip}:8789/byte/sync").to_return(status: 202, body: "{}")
    stub_request(:post, "http://#{ip}:8788/byte/sync").to_timeout

    expect(described_class.sync(:laptop)).to be(true)
    expect(described_class.sync(:mini)).to be(false)
  end

  it "always sends the desk-side calls to the laptop" do
    pet  = stub_request(:post, "http://#{ip}:8789/byte/pet").to_return(status: 200, body: "{}")
    mail = stub_request(:post, "http://#{ip}:8789/byte/label_mail").to_return(status: 200, body: "{}")

    described_class.pet(:feed, 10)
    described_class.label_mail(message_id: "<a@b>")

    expect(pet).to have_been_requested
    expect(mail).to have_been_requested
  end
end
