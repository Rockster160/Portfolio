require "rails_helper"

RSpec.describe Buddy::GPT::ImageTool do
  # DiskService#url needs url options; there's no request in a service spec.
  before { ActiveStorage::Current.url_options = { host: "example.com", protocol: "https" } }
  after  { ActiveStorage::Current.url_options = nil }

  let(:user)  { User.me }
  let(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy") }
  let(:tool)  { described_class.new(user, convo) }

  def said(body, conversation: convo)
    conversation.byte_messages.create!(
      user: user, direction: :outbound, state: :sent, body: body,
    )
  end

  def with_image(message, name: "chart.png")
    message.files.attach(io: StringIO.new("png-bytes"), filename: name, content_type: "image/png")
    message
  end

  def call(args={})
    JSON.parse(tool.call(args.stringify_keys))
  end

  it "reports what it opened and stages the pixels for the model to see" do
    msg = with_image(said("look at this"))

    result = call(message_id: msg.id)

    expect(result).to include("message_id" => msg.id, "images" => ["chart.png"])
    # A function_call_output is a string, so the image itself has to ride back
    # separately - Turn splices this in behind the output.
    staged = tool.drain_input
    expect(staged.size).to eq(1)
    expect(staged.first[:role]).to eq(:user)
    expect(staged.first[:content].pluck(:type)).to eq([:input_text, :input_image])
  end

  it "hands each staged item over only once, so a later round can't re-send it" do
    with_image(said("look"))

    call
    expect(tool.drain_input).not_to be_empty
    expect(tool.drain_input).to be_empty
  end

  it "opens the most recent image when no id is given" do
    with_image(said("first"), name: "old.png")
    newest = with_image(said("second"), name: "new.png")

    expect(call).to include("message_id" => newest.id, "images" => ["new.png"])
  end

  it "says so plainly when the thread has no images" do
    said("just talking")

    expect(call).to include("error" => a_string_matching(/haven't sent any images/))
  end

  it "refuses a message with no image on it" do
    msg = said("no picture here")

    expect(call(message_id: msg.id)).to include("error" => a_string_matching(/no image/))
  end

  # An id lifted from anywhere else should read as "not here" rather than
  # reaching into another thread.
  it "refuses an image from a different conversation" do
    other = user.byte_conversations.create!(mode: :buddy, name: "Other")
    msg   = with_image(said("elsewhere", conversation: other))

    expect(call(message_id: msg.id)).to include("error" => a_string_matching(/no message/))
    expect(tool.drain_input).to be_empty
  end

  # A model that keeps reaching for pictures burns the turn budget and the token
  # budget on the same photos.
  it "stops opening images past the per-turn cap" do
    msg = with_image(said("look"))

    described_class::MAX_PER_TURN.times { expect(call(message_id: msg.id)).not_to have_key("error") }

    expect(call(message_id: msg.id)).to include("error" => a_string_matching(/enough images/))
  end
end
