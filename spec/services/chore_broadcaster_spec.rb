require "rails_helper"

RSpec.describe ChoreBroadcaster do
  let(:user) { create(:user) }

  describe ".broadcast_changes!" do
    it "sends a single MonitorChannel message per recipient carrying chore_ids" do
      chore = create(:chore, created_by_user: user)
      broadcasts = []
      allow(MonitorChannel).to receive(:broadcast_to) { |recipient, payload|
        broadcasts << [recipient, payload]
      }

      described_class.broadcast_changes!(user, chore)

      expect(broadcasts.size).to eq(1)
      _, payload = broadcasts.first
      expect(payload[:data][:chore_id]).to eq(chore.id)
      expect(payload[:data][:chore_ids]).to eq([chore.id])
    end

    it "coalesces sub-chore taps into ONE broadcast carrying both ids in chore_ids" do
      parent = create(:chore, created_by_user: user)
      sub    = create(:chore, created_by_user: user, parent_chore: parent, one_off: true)
      broadcasts = []
      allow(MonitorChannel).to receive(:broadcast_to) { |recipient, payload|
        broadcasts << [recipient, payload]
      }

      described_class.broadcast_changes!(user, parent, related: sub)

      # Regression guard: prior behavior was TWO broadcasts (one per chore),
      # which multiplied client-side request fan-out (state fetch + shell
      # refresh) per recipient tab. Coalescing must stay ONE broadcast.
      expect(broadcasts.size).to eq(1)
      _, payload = broadcasts.first
      expect(payload[:data][:chore_id]).to eq(parent.id)
      expect(payload[:data][:chore_ids]).to match_array([parent.id, sub.id])
    end

    it "does not duplicate the id when related equals chore" do
      chore = create(:chore, created_by_user: user)
      broadcasts = []
      allow(MonitorChannel).to receive(:broadcast_to) { |recipient, payload|
        broadcasts << [recipient, payload]
      }

      described_class.broadcast_changes!(user, chore, related: chore)

      expect(broadcasts.size).to eq(1)
      _, payload = broadcasts.first
      expect(payload[:data][:chore_ids]).to eq([chore.id])
    end
  end
end
