require "rails_helper"

# The chore board: the kiosk's surface with one group of chores on it instead
# of the routine pad.
#
# It is addressed by CONVERSATION rather than by group, because the thread
# already decides the pet, the name, the palette and the voice - and because
# opening the same URL on a phone and on a tablet should be the same board.
# Which group it shows lives on the thread, so that follows too.
RSpec.describe "Byte chore board", type: :request do
  let(:user) { User.me }
  let!(:thread) {
    user.byte_conversations.create!(mode: :buddy, name: "Home", last_message_at: Time.current)
  }

  # The page lives on its own subdomain and the session cookie belongs to the
  # host it was issued on, so the host switch comes before the sign-in.
  def sign_in
    user.update!(password: "password123", password_confirmation: "password123")
    host! "byte.example.com"
    post login_path, params: { user: { username: user.username, password: "password123" } }
  end

  before { sign_in }

  def board_chores
    JSON.parse(response.body[/data-board-chores="([^"]*)"/, 1].to_s.gsub("&quot;", '"'))
  end

  describe "GET /board/:conversation_id" do
    it "renders the board surface rather than the routine pad" do
      get "/board/#{thread.id}"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-board="true"')
      expect(response.body).to include("data-byte-board")
      # Both are kiosk chrome - the board IS a kiosk with a different pad - but
      # the routine pad itself must not also be on screen. Two grids of big
      # targets is the state where you have to read before you can press.
      expect(response.body).to include('data-kiosk="true"')
      expect(response.body).not_to include("data-kiosk-pad")
    end

    it "carries only the thread's own group, serialized for the first paint" do
      thread.update!(metadata: thread.metadata.merge("chore_tag" => "Home"))
      create(:chore, created_by_user: user, name: "Vacuum", tag: "Home", marked_due_at: Time.current)
      create(:chore, created_by_user: user, name: "Feed Whisper", tag: "Pets", marked_due_at: Time.current)

      get "/board/#{thread.id}"

      expect(board_chores.pluck("name")).to eq(["Vacuum"])
      expect(board_chores.first["tag"]).to eq("Home")
    end

    # An unpointed board shows NOTHING rather than everything. A screen filled
    # with every chore in the house would look deliberate and be wrong.
    it "loads nothing at all when the thread has no group yet" do
      create(:chore, created_by_user: user, name: "Vacuum", tag: "Home", marked_due_at: Time.current)

      get "/board/#{thread.id}"

      expect(board_chores).to eq([])
      expect(response.body).to include("Pick a group")
    end

    # A board has no header and no composer, so without this there is no way
    # off it but the browser's own back button - and an installed board has no
    # browser chrome at all.
    it "offers a way back to the chat" do
      get "/board/#{thread.id}"

      expect(response.body).to include("Back to the chat")
    end

    it "falls through to a thread of the viewer's own when the id isn't theirs" do
      stranger = create(:user)
      theirs = stranger.byte_conversations.create!(
        mode: :buddy, name: "Not yours", last_message_at: Time.current,
      )

      get "/board/#{theirs.id}"

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("Not yours")
    end
  end

  # Discovery. The board is addressed by conversation, so the id has to come
  # from somewhere a person can see - the thread's own row in the drawer.
  describe "getting there" do
    it "offers a board row on the conversation menu" do
      get "/"

      expect(response.body).to include("data-byte-menu-board")
      expect(response.body).to include("Open chore board")
    end
  end

  describe "PATCH /byte/board/tag" do
    before { create(:chore, created_by_user: user, name: "Vacuum", tag: "Home") }

    it "points the thread's board at a group" do
      patch "/byte/board/tag", params: { conversation_id: thread.id, tag: "Home" }

      expect(response).to have_http_status(:ok)
      expect(thread.reload.chore_tag).to eq("Home")
    end

    # A typo'd group is a board that is permanently empty with nothing on the
    # screen to say why, so it is refused at the door rather than stored.
    it "refuses a group the household doesn't use, and says which it does" do
      patch "/byte/board/tag", params: { conversation_id: thread.id, tag: "Workshp" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["tags"]).to eq(["Home"])
      expect(thread.reload.chore_tag).to be_nil
    end

    it "clears it on a blank, which is how a board is unpointed" do
      thread.update!(metadata: thread.metadata.merge("chore_tag" => "Home"))

      patch "/byte/board/tag", params: { conversation_id: thread.id, tag: "" }

      expect(thread.reload.chore_tag).to be_nil
    end

    it "404s on somebody else's thread" do
      theirs = create(:user).byte_conversations.create!(mode: :buddy, last_message_at: Time.current)

      patch "/byte/board/tag", params: { conversation_id: theirs.id, tag: "Home" }

      expect(response).to have_http_status(:not_found)
      expect(theirs.reload.chore_tag).to be_nil
    end
  end

  describe "POST /byte/chore_cheer" do
    let!(:chore) { create(:chore, created_by_user: user, name: "Vacuum", short_name: "Vacuum") }

    it "answers with a line in the thread's own pet voice and wears the face" do
      thread.update_columns(buddy_theme: "kumoko", buddy_expression: "neutral")

      post "/byte/chore_cheer", params: { conversation_id: thread.id, chore_id: chore.id }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["say"]).to be_present
      expect(response.parsed_body["mood"]).to be_present
      # The column is the one writer of the pet's face, and the broadcast off
      # it is what repaints every open screen - so the cheer has to have moved
      # it rather than handing the client a mood to paint itself.
      expect(thread.reload.buddy_expression).to eq(response.parsed_body["mood"])
    end

    it "names the chore it is cheering" do
      post "/byte/chore_cheer", params: { conversation_id: thread.id, chore_id: chore.id }

      expect(response.parsed_body["say"]).to include("Vacuum")
    end

    # The waking line has no chore behind it at all, so it must not need one.
    it "says something on waking with no chore to name" do
      post "/byte/chore_cheer", params: { conversation_id: thread.id, kind: "wake" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["say"]).to be_present
      expect(response.parsed_body["say"]).not_to include("%")
    end

    it "404s on somebody else's thread" do
      theirs = create(:user).byte_conversations.create!(mode: :buddy, last_message_at: Time.current)

      post "/byte/chore_cheer", params: { conversation_id: theirs.id, chore_id: chore.id }

      expect(response).to have_http_status(:not_found)
    end
  end
end
