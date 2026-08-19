require "rails_helper"

RSpec.describe SystemController, type: :controller do
  render_views

  let(:me)      { FactoryBot.create(:user, phone: "5550005000", role: :admin) }
  let(:partner) { FactoryBot.create(:user, phone: "5550005001") }
  # No Buddy conversation, so no companion to tell.
  let(:absent)  { FactoryBot.create(:user, phone: "5550005002") }

  before do
    allow(User).to receive(:me).and_return(me)
    me_id = me.id
    allow_any_instance_of(User).to receive(:me?) { |u| u.id == me_id }
    sign_in(me)
    BuddyAnnouncement.delete_all
    # Having a Buddy conversation IS having a companion — the same gate the
    # relay uses. `absent` deliberately gets none.
    [me, partner].each { |u| u.byte_conversations.create!(mode: :buddy, last_message_at: Time.current) }
    absent
  end

  describe "GET #announcements" do
    it "lists what's queued and how far each got" do
      Buddy::Announcements.queue!(user: me, body: "The plumber is coming Thursday.")
      Buddy::Announcements.queue!(user: partner, body: "Bins go out tonight.").update!(delivered_at: 1.hour.ago)

      get(:announcements)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("The plumber is coming Thursday.", "pending")
      expect(response.body).to include("Bins go out tonight.", "delivered")
    end

    it "is refused to anyone who isn't me" do
      allow(User).to receive(:me).and_return(partner)
      allow_any_instance_of(User).to receive(:me?).and_return(false)

      get(:announcements)

      expect(response).not_to have_http_status(:ok)
    end
  end

  describe "POST #create_announcement" do
    it "queues one for a single person" do
      post(:create_announcement, params: { body: "The plumber is coming Thursday.", user_id: partner.id })

      expect(BuddyAnnouncement.pluck(:user_id)).to eq([partner.id])
      expect(flash[:notice]).to include(partner.first_name)
    end

    # One row each, because delivery is tracked per person — they read their
    # briefings at different times.
    it "queues a row per person when it goes to everyone" do
      post(:create_announcement, params: { body: "Power's out Saturday morning.", user_id: "all" })

      expect(BuddyAnnouncement.pluck(:user_id)).to contain_exactly(me.id, partner.id)
    end

    it "leaves out anyone with no companion to tell" do
      post(:create_announcement, params: { body: "Power's out Saturday.", user_id: "all" })

      expect(BuddyAnnouncement.pluck(:user_id)).not_to include(absent.id)
    end

    it "sets an expiry when one is chosen" do
      post(:create_announcement, params: { body: "Bins tonight.", user_id: me.id, expires_in_hours: "12" })

      expect(BuddyAnnouncement.last.expires_at).to be_within(1.minute).of(12.hours.from_now)
    end

    it "leaves it open-ended when no expiry is chosen" do
      post(:create_announcement, params: { body: "Bins tonight.", user_id: me.id, expires_in_hours: "" })

      expect(BuddyAnnouncement.last.expires_at).to be_nil
    end

    it "refuses an empty note" do
      post(:create_announcement, params: { body: "   ", user_id: me.id })

      expect(BuddyAnnouncement.count).to eq(0)
      expect(flash[:alert]).to be_present
    end

    it "says so rather than silently doing nothing when there's no one to tell" do
      post(:create_announcement, params: { body: "Something.", user_id: 999_999 })

      expect(BuddyAnnouncement.count).to eq(0)
      expect(flash[:alert]).to be_present
    end
  end

  describe "managing the queue" do
    it "deletes one that was queued by mistake" do
      ann = Buddy::Announcements.queue!(user: me, body: "Wrong thing.")

      expect { delete(:destroy_announcement, params: { id: ann.id }) }
        .to change(BuddyAnnouncement, :count).by(-1)
    end

    # The reason delivered_at is a stamp rather than a delete.
    it "puts a delivered one back in the queue" do
      ann = Buddy::Announcements.queue!(user: me, body: "Never actually heard.")
      Buddy::Announcements.claim_block!(me)

      patch(:requeue_announcement, params: { id: ann.id })

      expect(ann.reload.delivered_at).to be_nil
      expect(Buddy::Announcements.claim_block!(me)).to include("Never actually heard.")
    end
  end
end
