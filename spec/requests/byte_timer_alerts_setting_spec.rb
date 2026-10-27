require "rails_helper"

# A wall surface (a chore board, the kiosk) can turn its timer alerts off, and
# off means the chips never appear there — no ring, no face takeover — without
# quieting the chat, which is the home of the timers. Each board holds its own
# switch, and the kiosk the person's; one being off says nothing about another.
RSpec.describe "Byte timer alerts setting", type: :request do
  let(:user) { User.me }

  def sign_in
    user.update!(password: "password123", password_confirmation: "password123")
    post login_path, params: { user: { username: user.username, password: "password123" } }
  end

  # User.me is memoized process-wide, so the one instance is shared across
  # examples and a transaction rollback reverts the row but not the object's
  # loaded byte_prefs. Start each example from a clean slate so the per-surface
  # independence is read from what the example sets, not what leaked into it.
  before do
    sign_in
    user.update!(byte_prefs: {})
  end

  describe User do
    it "is on for a kiosk nobody has touched" do
      user.update!(byte_prefs: {})

      expect(user.byte_timer_alerts?(:kiosk)).to be(true)
    end

    it "round-trips the kiosk off and back on" do
      user.set_byte_timer_alerts(:kiosk, false)
      user.save!
      expect(user.reload.byte_timer_alerts?(:kiosk)).to be(false)

      user.set_byte_timer_alerts(:kiosk, true)
      user.save!
      expect(user.reload.byte_timer_alerts?(:kiosk)).to be(true)
    end

    it "leaves the rest of the preferences alone" do
      user.update!(byte_prefs: { "font_scale" => 130 })
      user.set_byte_timer_alerts(:kiosk, false)
      user.save!

      expect(user.reload.byte_font_scale).to eq(130)
    end

    it "ignores a surface that is not the kiosk" do
      user.set_byte_timer_alerts(:chat, false)
      user.set_byte_timer_alerts(:board, false)
      user.save!

      expect(user.reload.byte_prefs.to_h["timer_alerts"]).to be_blank
    end
  end

  describe "the endpoint" do
    let!(:board) {
      user.byte_conversations.create!(
        mode: :buddy, name: "Home", last_message_at: Time.current, metadata: { "board" => true },
      )
    }
    let!(:other) {
      user.byte_conversations.create!(
        mode: :buddy, name: "Desk", last_message_at: Time.current, metadata: { "board" => true },
      )
    }

    it "stores one board off, leaving the other boards and the kiosk on" do
      post byte_timer_alerts_path, params: { surface: "board", conversation_id: board.id, on: false }, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["on"]).to be(false)
      expect(board.reload.timer_alerts?).to be(false)
      expect(other.reload.timer_alerts?).to be(true)
      expect(user.reload.byte_timer_alerts?(:kiosk)).to be(true)
    end

    it "turns a board back on" do
      board.update!(metadata: board.metadata.merge("timer_alerts" => false))

      post byte_timer_alerts_path, params: { surface: "board", conversation_id: board.id, on: true }, as: :json

      expect(response.parsed_body["on"]).to be(true)
      expect(board.reload.timer_alerts?).to be(true)
    end

    it "refuses a board this person can't open" do
      theirs = create(:user).byte_conversations.create!(
        mode: :buddy, name: "Theirs", last_message_at: Time.current, metadata: { "board" => true },
      )

      post byte_timer_alerts_path, params: { surface: "board", conversation_id: theirs.id, on: false }, as: :json

      expect(response).to have_http_status(:not_found)
      expect(theirs.reload.timer_alerts?).to be(true)
    end

    it "stores the kiosk off and says so" do
      post byte_timer_alerts_path, params: { surface: "kiosk", on: false }, as: :json

      expect(response.parsed_body["surface"]).to eq("kiosk")
      expect(response.parsed_body["on"]).to be(false)
      expect(user.reload.byte_timer_alerts?(:kiosk)).to be(false)
      expect(board.reload.timer_alerts?).to be(true)
    end

    it "refuses an unknown surface" do
      post byte_timer_alerts_path, params: { surface: "chat", on: false }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "the surfaces" do
    # A board's own page carries its settings; /board is the index of them.
    let!(:board) {
      user.byte_conversations.create!(
        mode: :buddy, name: "Home", last_message_at: Time.current, metadata: { "board" => true },
      )
    }

    before {
      host! "byte.example.com"
      sign_in
    }

    it "offers the toggle on the board, pointed at the board's own switch" do
      get byte_board_thread_path(board)

      expect(response.body).to include("data-byte-timer-alerts")
      expect(response.body).to include('data-surface="board"')
    end

    it "reports the board off on its own page when it is off" do
      board.update!(metadata: board.metadata.merge("timer_alerts" => false))

      get byte_board_thread_path(board)

      expect(response.body).to include('data-timer-alerts="false"')
    end

    # The chat is the timers' home — it always shows them and never offers a
    # switch to take them away.
    it "does not offer the toggle in the chat" do
      get byte_root_path

      expect(response.body).not_to include("data-byte-timer-alerts")
      expect(response.body).to include('data-timer-alerts="true"')
    end
  end
end
