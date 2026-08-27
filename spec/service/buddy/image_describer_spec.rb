require "rails_helper"

RSpec.describe Buddy::ImageDescriber do
  let(:user) { User.me }
  # A real upload rather than a direct-upload placeholder: attaching one runs
  # analysis, which needs the bytes to actually be there.
  let(:blob) {
    ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("not really a jpeg"), filename: "shed.jpg", content_type: "image/jpeg",
    )
  }

  def model_says(text)
    fake = FakeBuddyClient.new([{ text: text }])
    allow(Buddy::GPT::Client).to receive(:new).and_return(fake)
    fake
  end

  before { allow(described_class).to receive(:source_url).and_return("https://example.test/shed.jpg") }

  it "writes what the picture is of, with its tags" do
    model_says('{"body": "Two bikes leaning against a shed door.", "tags": ["bike", "shed"]}')

    record = described_class.describe!(user: user, blob: blob, taken_at: 2.days.ago)

    expect(record.body).to eq("Two bikes leaning against a shed door.")
    expect(record.tag_list).to eq(%w[bike shed])
  end

  it "keeps when the picture arrived, not when it got described" do
    model_says('{"body": "A shed.", "tags": []}')
    taken = 3.days.ago.change(usec: 0)

    expect(described_class.describe!(user: user, blob: blob, taken_at: taken).taken_at).to eq(taken)
  end

  it "survives the model wrapping its JSON in a fence" do
    model_says("```json\n{\"body\": \"A shed.\", \"tags\": [\"shed\"]}\n```")

    expect(described_class.describe!(user: user, blob: blob, taken_at: Time.current).body).to eq("A shed.")
  end

  it "writes nothing rather than a wrong sentence when the reply isn't readable" do
    model_says("I'm not able to help with that.")

    expect(described_class.describe!(user: user, blob: blob, taken_at: Time.current)).to be_nil
    expect(ImageDescription.count).to eq(0)
  end

  it "writes nothing when the image came back empty" do
    model_says('{"body": "", "tags": []}')

    expect(described_class.describe!(user: user, blob: blob, taken_at: Time.current)).to be_nil
  end

  # A picture without a description is the situation before any of this
  # existed, and never a reason to fail whatever queued the work.
  it "does not raise when the call fails" do
    model_says(nil)
    allow(Buddy::GPT::Client).to receive(:new).and_return(FakeBuddyClient.new([{ error: "rate limited" }]))

    expect { described_class.describe!(user: user, blob: blob, taken_at: Time.current) }.not_to raise_error
    expect(ImageDescription.count).to eq(0)
  end

  # One photo sent in chat and then filed into inventory is one picture in two
  # places. Describing it twice would put two differently worded sentences on
  # the same image and return it twice.
  describe "the same picture turning up again" do
    it "records the new route instead of describing it a second time" do
      model_says('{"body": "A shed.", "tags": []}')
      described_class.describe!(user: user, blob: blob, taken_at: Time.current)
      expect(Buddy::GPT::Client).not_to receive(:new)

      again = described_class.describe!(user: user, blob: blob, taken_at: Time.current, box_key: "garage")

      expect(ImageDescription.count).to eq(1)
      expect(again.box_key).to eq("garage")
    end

    # The first place it landed is the one the description was written about.
    it "leaves a route that is already there alone" do
      model_says('{"body": "A shed.", "tags": []}')
      described_class.describe!(user: user, blob: blob, taken_at: Time.current, box_key: "garage")

      again = described_class.describe!(user: user, blob: blob, taken_at: Time.current, box_key: "attic")

      expect(again.box_key).to eq("garage")
    end
  end

  describe "what gets queued" do
    let(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Byte", last_message_at: Time.current) }

    before do
      allow(MonitorChannel).to receive(:broadcast_to)
      allow(BuddyDeliverWorker).to receive(:perform_async)
    end

    it "describes a photo the moment it is attached to a message" do
      allow(DescribeImageWorker).to receive(:perform_async)

      ByteMessageIntake.call(
        user: user, conversation: convo, body: "look at this",
        attachment_signed_ids: [blob.signed_id]
      )

      expect(DescribeImageWorker).to have_received(:perform_async).with(user.id, blob.id, hash_including("byte_message_id"))
    end

    it "queues nothing for a message with no pictures on it" do
      allow(DescribeImageWorker).to receive(:perform_async)

      ByteMessageIntake.call(user: user, conversation: convo, body: "just words")

      expect(DescribeImageWorker).not_to have_received(:perform_async)
    end

    it "queues nothing for a picture that already has a sentence on it" do
      model_says('{"body": "A shed.", "tags": []}')
      described_class.describe!(user: user, blob: blob, taken_at: Time.current)
      allow(DescribeImageWorker).to receive(:perform_async)

      DescribeImageWorker.enqueue_for(user: user, blobs: [blob], taken_at: Time.current, box_key: "garage")

      expect(DescribeImageWorker).not_to have_received(:perform_async)
      expect(ImageDescription.first.box_key).to eq("garage")
    end
  end
end
