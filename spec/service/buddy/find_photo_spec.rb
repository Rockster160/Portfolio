require "rails_helper"

# A picture is in front of the model for exactly one turn. Buddy::GPT::History
# fades the message to `[image #1234: IMG_4821.jpeg]` afterwards, which is the
# right trade for cost and the wrong one for recall - a filename is not a thing
# anybody remembers, and past the replay depth the photo may as well not exist.
# So each one gets a sentence when it arrives, and this searches those.
RSpec.describe "Buddy photo recall" do
  let(:user)  { User.me }
  let(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Byte", last_message_at: Time.current) }

  def described!(body, tags: [], taken_at: Time.current, message: nil, box_key: nil)
    ImageDescription.create!(
      user:         user,
      blob:         ActiveStorage::Blob.create_before_direct_upload!(
        filename: "p#{SecureRandom.hex(4)}.jpg", byte_size: 1, checksum: "x", content_type: "image/jpeg",
      ),
      body:         body,
      tags:         tags,
      taken_at:     taken_at,
      byte_message: message,
      box_key:      box_key,
    )
  end

  def answer(payload={})
    Buddy::GPT::Turn.resolve_tool(
      Buddy::Tools[:find_photo],
      { call_id: "call_1", name: :find_photo, arguments: payload },
      user: user, conversation: convo,
    )
  end

  before { allow(MonitorChannel).to receive(:broadcast_to) }

  describe "searching" do
    before do
      described!(
        "A close-up of the white label under a router, showing the model number and the wifi password.",
        tags: %w[router label wifi],
      )
      described!(
        "The back garden fence, two panels leaning where the post has rotted through at the base.",
        tags: %w[fence garden],
      )
    end

    it "finds a photo by what is in it" do
      found = Buddy::PhotoSearch.call(user: user, query: "router")

      expect(found[:photos].map(&:body).join).to include("router")
      expect(found[:total]).to eq(1)
    end

    it "finds one by a tag rather than the prose" do
      expect(Buddy::PhotoSearch.call(user: user, query: "wifi")[:photos].length).to eq(1)
    end

    # "the blue bike" narrowing to pictures with both is the point; anything
    # blue OR any bike is the whole album.
    it "requires every word, not any of them" do
      expect(Buddy::PhotoSearch.call(user: user, query: "router fence")[:photos]).to be_empty
    end

    it "is case-insensitive and matches inside a word" do
      expect(Buddy::PhotoSearch.call(user: user, query: "ROUT")[:photos].length).to eq(1)
    end

    it "narrows by when it was taken" do
      described!("A pallet of firewood stacked against the shed.", taken_at: 2.weeks.ago)

      found = Buddy::PhotoSearch.call(user: user, query: "firewood", since: 3.days.ago)

      expect(found[:photos]).to be_empty
    end

    it "narrows to one inventory box" do
      described!("A tangle of tent poles in a canvas bag.", box_key: "camping-tote")

      expect(Buddy::PhotoSearch.call(user: user, box: "camping-tote")[:photos].length).to eq(1)
    end

    it "reaches nothing belonging to somebody else" do
      other = create(:user)
      ImageDescription.create!(
        user: other, blob: ActiveStorage::Blob.create_before_direct_upload!(
          filename: "x.jpg", byte_size: 1, checksum: "x", content_type: "image/jpeg",
        ),
        body: "Another router label entirely.", taken_at: Time.current
      )

      expect(Buddy::PhotoSearch.call(user: user, query: "router")[:total]).to eq(1)
    end
  end

  # The frame the thread reserves for a picture is already the right size before
  # the bytes land; this is what fills it with something worth reading instead
  # of a pulsing rectangle, and it is the alt text for anyone who never gets the
  # picture at all.
  describe "what the thread renders while the picture is still loading" do
    it "carries the description out to the client" do
      message = convo.byte_messages.create!(
        user: user, direction: :outbound, state: :sent, body: "look at this",
      )
      message.files.attach(io: StringIO.new("bytes"), filename: "router.jpg", content_type: "image/jpeg")
      described!("A white label under a router.", message: message)
      ImageDescription.last.update!(blob: message.files.first.blob)

      expect(message.reload.as_wire[:attachments].first[:description]).to eq("A white label under a router.")
    end

    it "leaves the key off a picture nobody described" do
      message = convo.byte_messages.create!(
        user: user, direction: :outbound, state: :sent, body: "look at this",
      )
      message.files.attach(io: StringIO.new("bytes"), filename: "old.jpg", content_type: "image/jpeg")

      expect(message.reload.as_wire[:attachments].first).not_to have_key(:description)
    end
  end

  describe "the tool" do
    # `message_id` is the half that matters most: it's what `view_image` takes,
    # so a description that sounds right can be turned into the actual pixels in
    # the same turn.
    it "hands back the id the model needs to actually open it" do
      photo = convo.byte_messages.create!(
        user: user, direction: :outbound, state: :sent, body: "look at this",
      )
      described!("The white label under a router.", message: photo)

      expect(answer({ query: "router" })[:photos].first[:message_id]).to eq(photo.id)
    end

    it "says plainly when nothing matched instead of describing something unseen" do
      out = answer({ query: "kayak" })

      expect(out[:photos]).to be_empty
      expect(out[:how]).to match(/can't find one/i)
    end

    it "settles in the turn rather than leaving a row to tap" do
      expect(Buddy::Tools.answers?(Buddy::Tools[:find_photo])).to be(true)
    end
  end
end
