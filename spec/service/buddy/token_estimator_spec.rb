require "rails_helper"

RSpec.describe Buddy::TokenEstimator do
  let(:user)  { User.me }
  let(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy") }

  def said(body)
    convo.byte_messages.create!(user: user, direction: :outbound, state: :sent, body: body)
  end

  def with_image(message)
    message.files.attach(io: StringIO.new("png-bytes"), filename: "shot.png", content_type: "image/png")
    message
  end

  it "sizes a thread from its message bodies" do
    said("a" * 400)

    expect(described_class.estimate_for(convo)).to eq(120) # 400/4 + overhead
  end

  # Bodies alone say a photo costs nothing, which is the one case where char/4
  # isn't merely coarse but blind — an image is ~1,100 tokens.
  it "counts an image on the message about to be answered" do
    with_image(said("look"))

    expect(described_class.estimate_for(convo)).to be > described_class::IMAGE_TOKENS
  end

  # History sends the pixels once, on the turn the image arrives; every replay
  # after that is just its filename, so it stops costing anything.
  it "stops counting it once a newer message has arrived" do
    with_image(said("look"))
    said("and another thing")

    expect(described_class.estimate_for(convo)).to be < described_class::IMAGE_TOKENS
  end
end
