require "rails_helper"

RSpec.describe ActiveStorageSweepWorker do
  let(:user)  { User.me }
  let(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy") }

  def blob(created_at: 2.days.ago)
    travel_to(created_at) {
      ActiveStorage::Blob.create_and_upload!(
        io:           StringIO.new("bytes"),
        filename:     "shot.png",
        content_type: "image/png",
      )
    }
  end

  # /byte/uploads stores a blob the moment an image is picked, so a chip removed
  # from the tray or a composer walked away from leaves a file in S3 that no
  # record will ever point at. Rails has no built-in sweep for these.
  it "purges a blob no message ever claimed" do
    orphan = blob

    expect { described_class.new.perform }.to change(ActiveStorage::Blob, :count).by(-1)
    expect(ActiveStorage::Blob.exists?(orphan.id)).to be(false)
  end

  it "leaves a blob a message is holding" do
    message = convo.byte_messages.create!(user: user, direction: :outbound, state: :sent, body: "look")
    message.files.attach(blob)

    expect { described_class.new.perform }.not_to change(ActiveStorage::Blob, :count)
  end

  # "Unattached" is also true for the seconds between an upload and the send
  # that claims it, and for an image waiting in the offline outbound queue.
  it "leaves a fresh blob alone so an in-flight send can still claim it" do
    blob(created_at: 1.minute.ago)

    expect { described_class.new.perform }.not_to change(ActiveStorage::Blob, :count)
  end
end
