require "rails_helper"

RSpec.describe AgendaShare do
  let(:owner) { create(:user) }
  let(:other) { create(:user, phone: "5559876543") }
  let(:agenda) { create(:agenda, user: owner) }

  describe "default agenda on user creation" do
    it "auto-creates one named after the user's username for new standard users" do
      u = create(:user, username: "alice", phone: "5551112222")
      expect(u.agendas.pluck(:name)).to include("alice")
    end

    it "skips for guest users (no username yet)" do
      u = create(:user, role: :guest, username: nil, email: nil, phone: nil, password: nil, password_confirmation: nil)
      expect(u.agendas).to be_empty
    end

    it "backfills if an existing user with no agendas is saved" do
      u = create(:user, username: "bob", phone: "5552223333")
      u.agendas.destroy_all
      expect(u.agendas).to be_empty
      u.update!(dark_mode: true) # any save
      expect(u.agendas.pluck(:name)).to eq(["bob"])
    end
  end

  it "shares to a non-owner with editor by default" do
    share = AgendaShare.create!(agenda: agenda, user: other)
    expect(share.permission).to eq("editor")
  end

  it "rejects sharing back to the owner" do
    share = AgendaShare.new(agenda: agenda, user: owner)
    expect(share).not_to be_valid
    expect(share.errors[:user_id]).to include("is already the owner")
  end

  it "prevents duplicate shares for the same user" do
    AgendaShare.create!(agenda: agenda, user: other)
    dup = AgendaShare.new(agenda: agenda, user: other)
    expect(dup).not_to be_valid
  end

  describe "Agenda#access_users + broadcast! multi-recipient" do
    it "broadcasts to owner + every shared user" do
      AgendaShare.create!(agenda: agenda, user: other, permission: :viewer)
      expect(MonitorChannel).to receive(:broadcast_to).with(owner, hash_including(id: :agenda))
      expect(MonitorChannel).to receive(:broadcast_to).with(other, hash_including(id: :agenda))
      agenda.broadcast!
    end
  end

  describe "Agenda#editable_by?" do
    it "is true for the owner" do
      expect(agenda.editable_by?(owner)).to be true
    end

    it "is true for editor shares" do
      AgendaShare.create!(agenda: agenda, user: other, permission: :editor)
      expect(agenda.editable_by?(other)).to be true
    end

    it "is false for viewer shares" do
      AgendaShare.create!(agenda: agenda, user: other, permission: :viewer)
      expect(agenda.editable_by?(other)).to be false
    end
  end

  # Every non-guest user gets an auto-default agenda named after their
  # username (see User#ensure_default_agenda), so accessible_agendas always
  # includes that one in addition to whatever the test creates explicitly.
  describe "User#accessible_agendas / editable_agendas" do
    it "returns owned + shared agendas" do
      AgendaShare.create!(agenda: agenda, user: other, permission: :viewer)
      own = create(:agenda, user: other, name: "Own")
      expect(other.accessible_agendas.pluck(:id)).to include(agenda.id, own.id)
      expect(other.accessible_agendas.pluck(:id)).not_to include(create(:agenda, user: owner, name: "Hidden").id)
    end

    it "editable excludes viewer-permission shares" do
      AgendaShare.create!(agenda: agenda, user: other, permission: :viewer)
      own = create(:agenda, user: other, name: "Own")
      expect(other.editable_agendas.pluck(:id)).to include(own.id)
      expect(other.editable_agendas.pluck(:id)).not_to include(agenda.id)
    end

    it "editable includes editor-permission shares" do
      AgendaShare.create!(agenda: agenda, user: other, permission: :editor)
      own = create(:agenda, user: other, name: "Own")
      expect(other.editable_agendas.pluck(:id)).to include(agenda.id, own.id)
    end
  end

  describe "AgendaItem agenda_id change — combined per-user broadcast" do
    let(:other_agenda) { create(:agenda, user: owner, name: "Personal") }
    let(:item) { create(:agenda_item, agenda: agenda, kind: :task, name: "X", start_at: Time.current) }

    it "sends owner ONE broadcast containing both accessible agendas" do
      _item = item # touch
      target_id = other_agenda.id
      old_id = agenda.id
      received_payloads = []
      allow(MonitorChannel).to receive(:broadcast_to) { |_u, payload| received_payloads << payload }
      item.update!(agenda_id: other_agenda.id)

      # Owner has access to both — exactly one broadcast, payload includes both ids.
      owner_payloads = received_payloads.select { |p| p[:id] == :agenda }
      expect(owner_payloads.size).to eq(1)
      ids = owner_payloads.first[:data][:changed].map { |c| c[:agenda_id] }
      expect(ids).to contain_exactly(old_id, target_id)
    end

    it "doesn't leak the new agenda's info to a user who only has old access" do
      shared_user = create(:user, phone: "5557654321")
      AgendaShare.create!(agenda: agenda, user: shared_user, permission: :viewer)
      _item = item

      per_recipient = Hash.new { |h, k| h[k] = [] }
      allow(MonitorChannel).to receive(:broadcast_to) { |u, payload| per_recipient[u.id] << payload }
      item.update!(agenda_id: other_agenda.id)

      # shared_user can only see the OLD agenda. Their payload must not
      # mention the new agenda.
      payload = per_recipient[shared_user.id].first
      ids = payload[:data][:changed].map { |c| c[:agenda_id] }
      expect(ids).to eq([agenda.id])
      expect(ids).not_to include(other_agenda.id)
    end
  end
end
