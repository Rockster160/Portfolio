require "rails_helper"

# Tapping the pet: a fun face for a moment, a slightly lighter mood, and a
# board's dream put away until the next one.
RSpec.describe "Tapping the pet", type: :request do
  let(:user) { User.me }
  let!(:board) {
    user.byte_conversations.create!(
      mode: :buddy, name: "Home", last_message_at: Time.current, buddy_expression: "neutral",
      metadata: { "board" => true },
    )
  }

  def sign_in
    user.update!(password: "password123", password_confirmation: "password123")
    host! "byte.example.com"
    post login_path, params: { user: { username: user.username, password: "password123" } }
  end

  def pat!(convo=board)
    post "/byte/buddy/pat", params: { conversation_id: convo.id }, as: :json
    response.body.present? ? response.parsed_body : nil
  end

  before {
    sign_in
    allow(MonitorChannel).to receive(:broadcast_to)
  }

  it "flashes one of the pet's fun faces and tells every screen" do
    body = pat!

    expect(response).to have_http_status(:ok)
    expect(Buddy::Faces::TAPPED.map(&:to_s)).to include(body["flash"])
    expect(Buddy::Faces.selectable(board.buddy_theme).map(&:to_s)).to include(body["flash"])
    expect(MonitorChannel).to have_received(:broadcast_to).with(
      user, hash_including(data: hash_including(kind: :buddy_pat, conversation_id: board.id, flash: body["flash"])),
    )
  end

  it "puts the board's dream away from the moment it's tapped" do
    freeze_time {
      body = pat!

      expect(board.reload.dream_dismissed_at).to eq(Time.current.floor(3))
      expect(Time.zone.parse(body["dream_dismissed_at"])).to eq(Time.current.floor(3))
    }
  end

  it "lightens the mood a little each tap, never into a scowl or affection" do
    faces = Array.new(8) { pat!["expression"] }

    expect(faces.first).to eq("neutral")
    expect(faces.last).not_to eq("neutral")
    expect(faces.map(&:to_sym) & (Buddy::Faces::IRRITATED + Buddy::Faces::TENDER)).to be_empty
    expect(board.reload.buddy_expression).to eq(faces.last)
  end

  it "starts over from a face something else gave it" do
    4.times { pat! }
    board.update!(buddy_expression: "sad")

    expect(pat!["expression"]).to eq("sad")
  end

  it "leaves a sleeping pet asleep" do
    board.update!(buddy_expression: "sleeping")

    expect(pat!["expression"]).to eq("sleeping")
  end

  it "leaves somebody else's pet alone" do
    other = create(:user).byte_conversations.create!(mode: :buddy, name: "Theirs", last_message_at: Time.current)
    pat!(other)

    expect(response).to have_http_status(:not_found)
  end
end
