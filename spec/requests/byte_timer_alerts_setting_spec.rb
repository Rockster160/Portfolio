require "rails_helper"

# A wall surface (the chore board, the kiosk) can turn its timer alerts off, and
# off means the chips never appear there — no ring, no face takeover — without
# quieting the chat, which is the home of the timers. Each surface holds its own
# switch; one being off says nothing about the other.
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
    it "is on for a surface nobody has touched" do
      user.update!(byte_prefs: {})

      expect(user.byte_timer_alerts?(:board)).to be(true)
      expect(user.byte_timer_alerts?(:kiosk)).to be(true)
    end

    it "round-trips a surface off and back on" do
      user.set_byte_timer_alerts(:board, false)
      user.save!
      expect(user.reload.byte_timer_alerts?(:board)).to be(false)

      user.set_byte_timer_alerts(:board, true)
      user.save!
      expect(user.reload.byte_timer_alerts?(:board)).to be(true)
    end

    it "keeps the two surfaces independent" do
      user.set_byte_timer_alerts(:board, false)
      user.save!

      expect(user.reload.byte_timer_alerts?(:board)).to be(false)
      expect(user.byte_timer_alerts?(:kiosk)).to be(true)
    end

    it "leaves the rest of the preferences alone" do
      user.update!(byte_prefs: { "font_scale" => 130 })
      user.set_byte_timer_alerts(:kiosk, false)
      user.save!

      expect(user.reload.byte_font_scale).to eq(130)
    end

    it "ignores a surface that is not a wall surface" do
      user.set_byte_timer_alerts(:chat, false)
      user.save!

      expect(user.reload.byte_prefs.to_h["timer_alerts"]).to be_blank
    end
  end

  describe "the endpoint" do
    it "stores a surface off and says so" do
      post byte_timer_alerts_path, params: { surface: "board", on: false }, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["surface"]).to eq("board")
      expect(response.parsed_body["on"]).to be(false)
      expect(user.reload.byte_timer_alerts?(:board)).to be(false)
      expect(user.byte_timer_alerts?(:kiosk)).to be(true)
    end

    it "turns a surface back on and says so" do
      user.set_byte_timer_alerts(:kiosk, false)
      user.save!

      post byte_timer_alerts_path, params: { surface: "kiosk", on: true }, as: :json

      expect(response.parsed_body["on"]).to be(true)
      expect(user.reload.byte_timer_alerts?(:kiosk)).to be(true)
    end

    it "refuses an unknown surface" do
      post byte_timer_alerts_path, params: { surface: "chat", on: false }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "the surfaces" do
    before {
      host! "byte.example.com"
      sign_in
    }

    it "offers the toggle on the board, pointed at the board's own switch" do
      get byte_board_path

      expect(response.body).to include("data-byte-timer-alerts")
      expect(response.body).to include('data-surface="board"')
    end

    it "reports the board surface off on the app root when it is off" do
      user.set_byte_timer_alerts(:board, false)
      user.save!

      get byte_board_path

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
