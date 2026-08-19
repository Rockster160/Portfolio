require "rails_helper"

# `/today` — asking for the briefing by hand.
#
# The scheduled one is a recurring reminder and the hero chip that used to run
# one is long gone, so the only remaining way in was hoping the model reached
# for the `today_briefing` tool — which its own description tells it not to.
RSpec.describe ByteController, type: :controller do
  let(:user)  { FactoryBot.create(:user, phone: "5550006000", role: :admin) }
  let!(:buddy) {
    user.byte_conversations.create!(mode: :buddy, name: "Byte", last_message_at: Time.current)
  }

  around { |ex| Sidekiq::Testing.fake! { ex.run } }

  before do
    allow(User).to receive(:me).and_return(user)
    user_id = user.id
    allow_any_instance_of(User).to receive(:me?) { |u| u.id == user_id }
    sign_in(user)
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(ActionCable.server).to receive(:broadcast)
  end

  def send_command(body, conversation: buddy)
    post(:create_message, params: { id: conversation.id, body: body })
  end

  def seeds(conversation = buddy)
    conversation.byte_messages.where("metadata->>'buddy_action' = 'today'")
  end

  it "posts a briefing seed the turn can answer" do
    expect { send_command("/today") }.to change { seeds.count }.by(1)

    expect(response).to have_http_status(:ok)
    expect(seeds.last.body).to include("What's on for TODAY")
  end

  # A hand-run is exempt from the sleep guard: someone typing this at 2am has
  # already answered the question the guard exists to ask.
  it "runs even while Buddy is asleep" do
    allow(Buddy::SleepGuard).to receive(:sleeping?).and_return(true)

    expect { send_command("/today") }.to change { seeds.count }.by(1)
  end

  it "is marked as a hand-run rather than the scheduled one" do
    send_command("/today")

    expect(seeds.last.metadata["source"]).to eq("quick_action")
  end

  # The briefing IS the answer, and it opens with a greeting. A line above
  # saying it's coming is the receipt the tool already refuses.
  it "says nothing of its own — no acknowledgement above the briefing" do
    send_command("/today")

    expect(buddy.byte_messages.where("metadata->>'kind' = 'system'")).to be_empty
  end

  it "hands back the seed, which the client drops on sight" do
    send_command("/today")

    body = JSON.parse(response.body)
    expect(body["metadata"]["hidden"]).to be(true)
    expect(body["id"]).to eq(seeds.last.id)
  end

  # The dispatcher accepts either prefix; period is closer to the space bar.
  it "answers to the period form too" do
    expect { send_command(".today") }.to change { seeds.count }.by(1)
  end

  it "never reaches the model as an ordinary message" do
    send_command("/today")

    expect(buddy.byte_messages.where(body: "/today")).to be_empty
  end

  context "in a thread that isn't Buddy's" do
    let!(:claude) {
      user.byte_conversations.create!(mode: :claude, name: "Claude", last_message_at: Time.current)
    }

    it "says so instead of briefing" do
      expect { send_command("/today", conversation: claude) }.not_to change { seeds(claude).count }

      expect(claude.byte_messages.last.body).to include("Buddy thing")
    end
  end
end
