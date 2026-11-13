require "rails_helper"

RSpec.describe Buddy::BoardYell do
  let(:user) { User.me }
  let(:housemate) { FactoryBot.create(:user) }
  let!(:kitchen) { board!(user, "Kitchen") }
  let!(:office) { board!(user, "Office") }

  before { allow(MonitorChannel).to receive(:broadcast_to) }

  def board!(owner, name, shared: false)
    meta = { "board" => true, "chore_tags" => ["Chores"] }
    meta["shared"] = true if shared
    owner.byte_conversations.create!(mode: :buddy, name: name, last_message_at: Time.current, metadata: meta)
  end

  def yell!(board: "Kitchen", key: "dinner", body: "🍕 Dinner's ready", **opts)
    described_class.yell!(user: user, board: board, key: key, body: body, **opts)
  end

  describe ".yell!" do
    it "yells on the board it names, case aside, with a leading emoji as the icon" do
      expect(yell!(board: "kitchen")).to eq([kitchen])

      yells = described_class.wire(kitchen.reload)
      expect(yells.size).to eq(1)
      expect(yells.first).to include("key" => "dinner", "body" => "Dinner's ready", "icon" => "🍕")
      expect(described_class.wire(office.reload)).to be_empty
    end

    it "yells nowhere with no board named, or one that doesn't exist" do
      expect(yell!(board: nil)).to be_empty
      expect(yell!(board: "Garage")).to be_empty
      expect(described_class.wire(kitchen.reload)).to be_empty
      expect(described_class.wire(office.reload)).to be_empty
    end

    it "yells on every board for all" do
      expect(yell!(board: "all")).to contain_exactly(kitchen, office)
    end

    it "reaches a board a housemate shared, and tells everyone who can see it" do
      house = ChoreHousehold.create!(name: "Home", owner_user: housemate)
      housemate.update!(chore_household_id: house.id)
      user.update!(chore_household_id: house.id)
      porch = board!(housemate, "Porch", shared: true)
      board!(housemate, "Private")

      expect(yell!(board: "porch")).to eq([porch])
      expect(yell!(board: "private")).to be_empty
      sent = hash_including(data: hash_including(kind: :board_yells, conversation_id: porch.id))
      expect(MonitorChannel).to have_received(:broadcast_to).with(housemate, sent)
      expect(MonitorChannel).to have_received(:broadcast_to).with(user, sent)
    end

    it "keeps a sound as the notes it plays, and drops a bare name" do
      yell!(sound: [[400, 392, 0.9, "sine"], [200, 0, 0, nil]])
      yell!(key: "other", sound: "alarm")

      sounds = described_class.yells(kitchen.reload).transform_values { |y| y["sound"] }
      expect(sounds).to eq("dinner" => [[400, 392.0, 0.9, "sine"], [200, 0, 0, nil]], "other" => nil)
    end

    it "replaces the words under a standing key rather than adding a second" do
      yell!(body: "Dinner in 5")
      yell!(body: "Dinner's ready")

      expect(described_class.wire(kitchen.reload).pluck("body")).to eq(["Dinner's ready"])
    end

    it "stops on its own once its minutes run out, but not a newer telling" do
      allow(BuddyBoardYellExpireWorker).to receive(:perform_at)
      freeze_time {
        yell!(minutes: 10)
        expected = [10.minutes.from_now, kitchen.id, "dinner", Time.current.iso8601(3)]
        expect(BuddyBoardYellExpireWorker).to have_received(:perform_at).with(*expected)
      }
      first = described_class.yells(kitchen.reload)["dinner"]["raised_at"]

      travel 1.minute
      yell!(minutes: 10)
      BuddyBoardYellExpireWorker.new.perform(kitchen.id, "dinner", first)
      expect(described_class.yells(kitchen.reload)).to have_key("dinner")

      travel 11.minutes
      expect(described_class.wire(kitchen.reload)).to be_empty
      second = kitchen.metadata["yells"]["dinner"]["raised_at"]
      BuddyBoardYellExpireWorker.new.perform(kitchen.id, "dinner", second)
      expect(kitchen.reload.metadata).not_to have_key("yells")
    end
  end

  describe ".resolve!" do
    it "stops the yell under the key on every board, and leaves others standing" do
      yell!(board: "all")
      yell!(board: "Office", key: "mail", body: "📬 Mail's here")

      expect(described_class.resolve!(user: user, key: "dinner")).to contain_exactly(kitchen, office)
      expect(described_class.wire(kitchen.reload)).to be_empty
      expect(described_class.wire(office.reload).pluck("key")).to eq(["mail"])
      expect(described_class.resolve!(user: user, key: "dinner")).to be_empty
    end
  end

  describe "a tap on the pet" do
    it "stops every yell on that board" do
      yell!(board: "all")

      Buddy::Pat.call(kitchen)

      expect(described_class.wire(kitchen.reload)).to be_empty
      expect(described_class.wire(office.reload)).not_to be_empty
    end
  end
end
