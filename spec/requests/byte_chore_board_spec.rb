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

  def board_items
    JSON.parse(response.body[/data-board-items="([^"]*)"/, 1].to_s.gsub("&quot;", '"'))
  end
  # Back-compat alias for the chore-only assertions below.
  alias_method :board_chores, :board_items

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

    it "carries only the thread's own groups, serialized for the first paint" do
      thread.update!(metadata: thread.metadata.merge("chore_tags" => ["Home"]))
      create(:chore, created_by_user: user, name: "Vacuum", tags: ["Home"], marked_due_at: Time.current)
      create(:chore, created_by_user: user, name: "Feed Whisper", tags: ["Pets"], marked_due_at: Time.current)

      get "/board/#{thread.id}"

      expect(board_chores.pluck("name")).to eq(["Vacuum"])
      expect(board_chores.first["tags"]).to eq(["Home"])
    end

    it "gathers chores from ANY of the groups it watches" do
      thread.update!(metadata: thread.metadata.merge("chore_tags" => ["Home", "Pets"]))
      create(:chore, created_by_user: user, name: "Vacuum", tags: ["Home"], marked_due_at: Time.current)
      create(:chore, created_by_user: user, name: "Feed Whisper", tags: ["Pets"], marked_due_at: Time.current)
      create(:chore, created_by_user: user, name: "Taxes", tags: ["Admin"], marked_due_at: Time.current)

      get "/board/#{thread.id}"

      expect(board_chores.pluck("name")).to contain_exactly("Vacuum", "Feed Whisper")
    end

    # A board set before groups went plural keeps watching what it did, read off
    # the old single `chore_tag` key until it is next changed.
    it "still honours a board pointed at a group the old way" do
      thread.update!(metadata: thread.metadata.merge("chore_tag" => "Home"))
      create(:chore, created_by_user: user, name: "Vacuum", tags: ["Home"], marked_due_at: Time.current)

      get "/board/#{thread.id}"

      expect(board_chores.pluck("name")).to eq(["Vacuum"])
    end

    # An unpointed board shows NOTHING rather than everything. A screen filled
    # with every chore in the house would look deliberate and be wrong.
    it "loads nothing at all when the thread has no group yet" do
      create(:chore, created_by_user: user, name: "Vacuum", tags: ["Home"], marked_due_at: Time.current)

      get "/board/#{thread.id}"

      expect(board_chores).to eq([])
      expect(response.body).to include("Pick groups")
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

  # A board shows one GROUP, and a group can hold chores (tick to complete) and
  # triggers (routines, tapped to fire) side by side. A trigger is stateless -
  # it has no occurrence to settle - so it carries only what a circle paints
  # from, tagged `kind: "trigger"` so the client knows not to draw a ring.
  def routine!(name:, tag:, enabled: true, position: nil)
    user.buddy_routines.create!(
      name:     name,
      tags:     Array(tag),
      enabled:  enabled,
      position: position,
      steps:    [BuddyRoutine.step(:log_event, { name: "ping" })],
    )
  end

  describe "triggers on the board" do
    before { thread.update!(metadata: thread.metadata.merge("chore_tag" => "Work")) }

    it "carries the group's triggers as stateless items, after its chores" do
      create(:chore, created_by_user: user, name: "Daily task", tags: ["Work"], marked_due_at: Time.current)
      routine!(name: "Focus mode", tag: "Work")
      # Neither of these belongs on this board: one is another group, the other
      # is switched off.
      routine!(name: "Away mode", tag: "Home")
      routine!(name: "Break mode", tag: "Work", enabled: false)

      get "/board/#{thread.id}"

      expect(board_items.pluck("kind")).to eq(["chore", "trigger"])
      trigger = board_items.last
      expect(trigger["name"]).to eq("Focus mode")
      expect(trigger["short_name"]).to eq("Focus mode")
      # No occurrence, so none of the chore state fields - the client reads the
      # kind and never looks for a ring to fill.
      expect(trigger).not_to have_key("progress_count")
      expect(trigger).not_to have_key("target_count")
    end

    it "serves the merged live set from GET /byte/board/items for resync" do
      create(:chore, created_by_user: user, name: "Daily task", tags: ["Work"], marked_due_at: Time.current)
      routine!(name: "Focus mode", tag: "Work")

      get "/byte/board/items", params: { conversation_id: thread.id }

      expect(response).to have_http_status(:ok)
      kinds = response.parsed_body["items"].pluck("kind")
      expect(kinds).to eq(["chore", "trigger"])
    end

    it "404s the items endpoint on somebody else's thread" do
      theirs = create(:user).byte_conversations.create!(mode: :buddy, last_message_at: Time.current)

      get "/byte/board/items", params: { conversation_id: theirs.id }

      expect(response).to have_http_status(:not_found)
    end
  end

  # Credit buttons: custom board buttons that complete a chore crediting a chosen
  # household member — the "Dishes, by X" button beside "Dishes, by me".
  describe "credit buttons" do
    let!(:housemate) { create(:user, chore_household_id: user.chore_household_id) }
    let!(:chore) {
      create(
        :chore, created_by_user: user, name: "Dishes",
        chore_household_id: user.chore_household_id, show_on_today_view: :always
      )
    }

    def credit_button!(**attrs)
      ChoreCreditButton.create!({
        chore_household_id: user.chore_household_id,
        created_by_user:    user,
        chore:              chore,
        credit_user:        housemate,
        tags:               ["Shared"],
        label:              "Dishes, by mate",
        color:              "#6366F1",
      }.merge(attrs))
    end

    it "carries a group's credit buttons on the board set, tagged as credit" do
      thread.update!(metadata: thread.metadata.merge("chore_tag" => "Shared"))
      credit_button!

      get "/board/#{thread.id}"

      item = board_items.find { |i| i["kind"] == "credit" }
      expect(item).to be_present
      expect(item["short_name"]).to eq("Dishes, by mate")
      expect(item["color"]).to eq("#6366F1")
    end

    it "presses a button: credits the chosen member, recorded by the presser" do
      btn = credit_button!

      expect {
        post "/byte/board/buttons/#{btn.id}/press"
      }.to change { ChoreCompletion.where(chore: chore, user: housemate).count }.by(1)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["credited"]).to eq(housemate.username)
      completion = ChoreCompletion.where(chore: chore, user: housemate).order(:id).last
      expect(completion.recorded_by_user_id).to eq(user.id)
    end

    # The whole constraint: a board is only ever a board. Pressing a credit
    # button on one thread must not touch which Buddy is the person's primary.
    it "a press leaves the primary Buddy untouched" do
      ByteConversation.pin_primary!(thread)
      before = ByteConversation.primary_for(user).id
      btn = credit_button!

      post "/byte/board/buttons/#{btn.id}/press"

      expect(ByteConversation.primary_for(user).id).to eq(before)
    end

    it "lists its buttons for a group with the chore and member options" do
      credit_button!

      get "/byte/board/buttons", params: { tags: "Shared" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["buttons"].pluck("label")).to eq(["Dishes, by mate"])
      expect(response.parsed_body["chores"].pluck("name")).to include("Dishes")
      expect(response.parsed_body["members"].pluck("id")).to include(housemate.id)
      # A new button credits the current user by default.
      expect(response.parsed_body["me"]).to eq(user.id)
    end

    it "creates, updates and deletes a button" do
      post "/byte/board/buttons", params: {
        button: {
          tags_csv:       "Shared, Kitchen",
          label:          "Dishes, by me",
          color:          "#16A34A",
          chore_id:       chore.id,
          credit_user_id: user.id,
        },
      }
      expect(response).to have_http_status(:created)
      expect(response.parsed_body["tags"]).to eq(["Shared", "Kitchen"])
      id = response.parsed_body["id"]

      patch "/byte/board/buttons/#{id}", params: { button: { label: "Dishes — me" } }
      expect(response.parsed_body["label"]).to eq("Dishes — me")

      expect {
        delete "/byte/board/buttons/#{id}"
      }.to change(ChoreCreditButton, :count).by(-1)
    end

    it "refuses a chore from another household" do
      stranger = create(:user)
      theirs = create(:chore, created_by_user: stranger, name: "Not ours")

      post "/byte/board/buttons", params: {
        button: { tags_csv: "Shared", label: "nope", chore_id: theirs.id, credit_user_id: user.id },
      }

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "GET /byte/board/tags" do
    it "unions the household's chore groups with the viewer's routine groups" do
      create(:chore, created_by_user: user, name: "Vacuum", tags: ["Home"])
      routine!(name: "Focus mode", tag: "Work")

      get "/byte/board/tags"

      expect(response.parsed_body["tags"]).to eq(["Home", "Work"])
    end
  end

  describe "PATCH /byte/board/tag" do
    before { create(:chore, created_by_user: user, name: "Vacuum", tags: ["Home"]) }

    it "points the thread's board at a group" do
      patch "/byte/board/tag", params: { conversation_id: thread.id, tag: "Home" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["chore_tags"]).to eq(["Home"])
      expect(thread.reload.chore_tags).to eq(["Home"])
    end

    it "points a board at several groups at once" do
      create(:chore, created_by_user: user, name: "Feed Whisper", tags: ["Pets"])

      patch "/byte/board/tag", params: { conversation_id: thread.id, tags: ["Home", "Pets"] }

      expect(response).to have_http_status(:ok)
      expect(thread.reload.chore_tags).to eq(["Home", "Pets"])
    end

    # A typo'd group is a board that is permanently empty with nothing on the
    # screen to say why, so it is refused at the door rather than stored.
    it "refuses a group the household doesn't use, and says which it does" do
      patch "/byte/board/tag", params: { conversation_id: thread.id, tag: "Workshp" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["tags"]).to eq(["Home"])
      expect(thread.reload.chore_tags).to eq([])
    end

    # One bad group in the set fails the whole change — a board half-pointed at
    # what you asked for is a surprise, not a convenience.
    it "refuses the set when any group in it is unknown" do
      create(:chore, created_by_user: user, name: "Feed Whisper", tags: ["Pets"])

      patch "/byte/board/tag", params: { conversation_id: thread.id, tags: ["Home", "Workshp"] }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(thread.reload.chore_tags).to eq([])
    end

    # A group that holds only triggers is a real board, so it has to be settable
    # even though no chore wears the tag.
    it "accepts a group that only has triggers" do
      routine!(name: "Focus mode", tag: "Focus")

      patch "/byte/board/tag", params: { conversation_id: thread.id, tag: "Focus" }

      expect(response).to have_http_status(:ok)
      expect(thread.reload.chore_tag).to eq("Focus")
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
