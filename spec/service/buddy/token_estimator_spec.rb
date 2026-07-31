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

  # Bodies alone say a thread of photos costs nothing, which is the one case
  # where char/4 isn't merely coarse but blind — an image is ~1,100 tokens and
  # gets replayed on every turn it's still in History's window.
  it "counts an attached image, which a body-only estimate can't see" do
    with_image(said("look"))

    expect(described_class.estimate_for(convo)).to be > described_class::IMAGE_TOKENS
  end

  it "stops counting an image once it falls out of the replay depth" do
    with_image(said("look"))
    (Buddy::GPT::History::IMAGE_REPLAY_DEPTH + 1).times { |i| said("later #{i}") }

    expect(described_class.estimate_for(convo)).to be < described_class::IMAGE_TOKENS
  end
end
