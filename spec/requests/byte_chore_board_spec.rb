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
    user.byte_conversations.create!(
      mode: :buddy, name: "Home", last_message_at: Time.current,
      metadata: { "board" => true },
    )
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

    # The background-process strip ("Reading mail", an application filling in) is
    # scoped to the account, not the thread - it belongs to the chat. A board is
    # its own surface and must not carry the account's machinery, so the strip is
    # left out of the DOM entirely here.
    it "does not carry the account's background-process strip" do
      get "/board/#{thread.id}"

      expect(response.body).not_to include("data-buddy-processes")
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

    # Top-to-bottom by when they came due: today first, then the most recently
    # missed, oldest last. `marked_due_at` fixes each chore's effective due day.
    it "orders chores by due date, most recently due first" do
      thread.update!(metadata: thread.metadata.merge("chore_tags" => ["Home"]))
      create(:chore, created_by_user: user, name: "Older", tags: ["Home"], marked_due_at: 3.days.ago)
      create(:chore, created_by_user: user, name: "Today", tags: ["Home"], marked_due_at: Time.current)
      create(:chore, created_by_user: user, name: "Yesterday", tags: ["Home"], marked_due_at: 1.day.ago)

      get "/board/#{thread.id}"

      expect(board_chores.pluck("name")).to eq(["Today", "Yesterday", "Older"])
    end

    # Due-today chores keep the manual Grid order among themselves, so chores a
    # person grouped together stay together — the way they read on Today, where
    # the not-due chores between them drop out. Carryovers follow, by recency.
    it "keeps due-today chores in Grid order, with carryovers after them" do
      thread.update!(metadata: thread.metadata.merge("chore_tags" => ["Home"]))
      create(:chore, created_by_user: user, name: "Alpha", tags: ["Home"], sort_order: 1, marked_due_at: Time.current)
      create(:chore, created_by_user: user, name: "MidCarry", tags: ["Home"], sort_order: 2, marked_due_at: 2.days.ago)
      create(:chore, created_by_user: user, name: "Zeta", tags: ["Home"], sort_order: 3, marked_due_at: Time.current)

      get "/board/#{thread.id}"

      expect(board_chores.pluck("name")).to eq(["Alpha", "Zeta", "MidCarry"])
    end

    # The sort leans on things that move during the day (a mark-due cleared, a
    # follower's due date settling), so a board keeps the order its chores took
    # when the day began and only a NEW chore finds its place in it.
    it "keeps the day's order when the sort would shuffle it, fitting new chores in" do
      thread.update!(metadata: thread.metadata.merge("chore_tags" => ["Home"]))
      older = create(:chore, created_by_user: user, name: "Older", tags: ["Home"], marked_due_at: 3.days.ago)
      create(:chore, created_by_user: user, name: "Today", tags: ["Home"], marked_due_at: Time.current)
      create(:chore, created_by_user: user, name: "Yesterday", tags: ["Home"], marked_due_at: 1.day.ago)
      get "/byte/board/items", params: { conversation_id: thread.id }

      older.update!(marked_due_at: Time.current)
      create(:chore, created_by_user: user, name: "Newer", tags: ["Home"], marked_due_at: 2.days.ago)
      get "/byte/board/items", params: { conversation_id: thread.id }

      expect(response.parsed_body["items"].pluck("name")).to eq(["Today", "Yesterday", "Newer", "Older"])
    end

    it "sorts afresh on a new chore day" do
      thread.update!(metadata: thread.metadata.merge("chore_tags" => ["Home"]))
      older = create(:chore, created_by_user: user, name: "Older", tags: ["Home"], marked_due_at: 3.days.ago)
      create(:chore, created_by_user: user, name: "Yesterday", tags: ["Home"], marked_due_at: 1.day.ago)
      get "/byte/board/items", params: { conversation_id: thread.id }

      older.update!(marked_due_at: Time.current)
      stale = thread.reload.metadata["board_order"].merge("day" => (Date.current - 1).iso8601)
      thread.update!(metadata: thread.metadata.merge("board_order" => stale))
      get "/byte/board/items", params: { conversation_id: thread.id }

      expect(response.parsed_body["items"].pluck("name")).to eq(["Older", "Yesterday"])
    end

    # The board draws its pet's chore dreams the way the morning hot picks are
    # drawn, so a hot chore carries the weight that draw would give it.
    it "weights a hot chore the way the hot-pick draw does" do
      thread.update!(metadata: thread.metadata.merge("chore_tags" => ["Home"]))
      hot = create(:chore, created_by_user: user, name: "Hot", tags: ["Home"], priority: :high, marked_due_at: Time.current)
      create(:chore, created_by_user: user, name: "Cold", tags: ["Home"], marked_due_at: Time.current)
      ChoreHotPick.create!(day_key: ChoreDay.current(user), chore_id: hot.id, multiplier: 2.0)

      get "/byte/board/items", params: { conversation_id: thread.id }

      by_name = response.parsed_body["items"].index_by { |item| item["name"] }
      expected = ChoreDailyResetWorker.new.selection_weights([hot], ChoreDay.current(user))[hot.id]
      expect(by_name["Hot"]["hot_weight"]).to eq(expected)
      expect(by_name["Hot"]["hot_weight"]).to be_positive
      expect(by_name["Cold"]).not_to have_key("hot_weight")
    end

    # A wall screen asks this after its socket comes back, and reloads itself
    # when a fresh page would carry a different version from its own.
    it "answers the version a fresh page would carry" do
      get "/byte/version"

      expect(response.parsed_body["version"]).to eq(ByteShellVersion.current)
    end

    it "carries a thought bubble for the pet's dreams" do
      get "/board/#{thread.id}"

      expect(response.body).to include("data-board-dream")
      expect(response.body).to include('data-version-url="/byte/version"')
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
    # browser chrome at all. Boards are their own kind of thread now, so the way
    # out leads to the board index rather than the chat.
    it "offers a way back to the board index" do
      get "/board/#{thread.id}"

      expect(response.body).to include("All boards")
      expect(response.body).to include("href=\"#{byte_board_path}\"")
    end

    it "redirects to the board index when the id isn't a board of the viewer's" do
      stranger = create(:user)
      theirs = stranger.byte_conversations.create!(
        mode: :buddy, name: "Not yours", last_message_at: Time.current,
        metadata: { "board" => true },
      )

      get "/board/#{theirs.id}"

      expect(response).to redirect_to(byte_board_path)
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

    it "carries the group's triggers as stateless items, before its chores" do
      create(:chore, created_by_user: user, name: "Daily task", tags: ["Work"], marked_due_at: Time.current)
      routine!(name: "Focus mode", tag: "Work")
      # Neither of these belongs on this board: one is another group, the other
      # is switched off.
      routine!(name: "Away mode", tag: "Home")
      routine!(name: "Break mode", tag: "Work", enabled: false)

      get "/board/#{thread.id}"

      # The one-press actions lead; the chores, which carry the day's state, follow.
      expect(board_items.pluck("kind")).to eq(["trigger", "chore"])
      trigger = board_items.first
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
      expect(kinds).to eq(["trigger", "chore"])
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
      # A board can't be primary, so the person's primary is a separate thread;
      # pressing a credit button on the board must not disturb it.
      primary = user.byte_conversations.create!(mode: :buddy, name: "Byte", last_message_at: Time.current)
      ByteConversation.pin_primary!(primary)
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
    it "unions the household's chore groups with the viewer's routine groups, reserved groups first" do
      create(:chore, created_by_user: user, name: "Vacuum", tags: ["Home"])
      routine!(name: "Focus mode", tag: "Work")

      get "/byte/board/tags"

      # "All" and "Whisper" lead: no chore or routine carries them, so they would
      # never appear on their own, but a board has to be able to watch them.
      expect(response.parsed_body["tags"]).to eq(["All", "Whisper", "Home", "Work"])
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

    it "broadcasts the change so other open copies of the board re-scope live" do
      expect(MonitorChannel).to receive(:broadcast_to).with(
        user, hash_including(data: hash_including(kind: :conversation)),
      )

      patch "/byte/board/tag", params: { conversation_id: thread.id, tag: "Home" }
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
      expect(response.parsed_body["tags"]).to eq(["All", "Whisper", "Home"])
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

  # A search for what the board keeps off. Each top-level term hides on its own;
  # parentheses join terms into one.
  describe "hidden filter" do
    def board_names(filter)
      thread.update!(metadata: thread.metadata.merge("chore_tags" => ["All"], "hidden_chore_filter" => filter))
      get "/board/#{thread.id}"
      board_items.pluck("name")
    end

    let!(:housemate) { create(:user, username: "Housemate", chore_household_id: user.chore_household_id) }

    before do
      create(:chore, created_by_user: user, name: "Vacuum", tags: ["Home"], marked_due_at: Time.current)
      create(:chore, created_by_user: user, name: "Puppy Fed", marked_due_at: Time.current)
      create(:chore, created_by_user: user, name: "Brush Fae", tags: ["Pet"], marked_due_at: Time.current)
      create(:chore, created_by_user: user, name: "Bathe Fae", marked_due_at: Time.current)
      create(:chore, created_by_user: user, name: "Drink Water", marked_due_at: Time.current)
      create(
        :chore, created_by_user: user, name: "Her laundry", assigned_to_user: housemate,
        sharing_mode: :household, marked_due_at: Time.current
      )
    end

    it "hides a chore by name, even on an All board" do
      expect(board_names('"Puppy Fed"')).not_to include("Puppy Fed")
      expect(board_names('"Puppy Fed"')).to include("Vacuum")
    end

    it "reads plain words in a row as one name" do
      create(:chore, created_by_user: user, name: "Fed the fish", marked_due_at: Time.current)
      names = board_names("Puppy Fed group:home")

      expect(names).not_to include("Puppy Fed", "Vacuum")
      expect(names).to include("Fed the fish")
      expect(Chore.board_hidden_terms("Puppy Fed group:home NOT Drink Water")).to eq(
        ['"Puppy Fed"', "group:home", 'NOT "Drink Water"'],
      )
    end

    it "hides a whole group" do
      expect(board_names("group:home")).not_to include("Vacuum")
    end

    it "hides each term on its own, and a parenthesized one only where all of it matches" do
      names = board_names('(group:pet Fae) "Drink Water"')

      expect(names).not_to include("Brush Fae", "Drink Water")
      expect(names).to include("Bathe Fae", "Vacuum")
    end

    it "hides what is assigned to someone" do
      expect(board_names("assignee:Housemate")).not_to include("Her laundry")
    end

    it "saves the filter, and refuses one it can't read" do
      post "/byte/board/hidden", params: { conversation_id: thread.id, filter: " group:home " }

      expect(response.parsed_body["hidden_filter"]).to eq("group:home")
      expect(thread.reload.hidden_chore_filter).to eq("group:home")

      post "/byte/board/hidden", params: { conversation_id: thread.id, filter: "(" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(thread.reload.hidden_chore_filter).to eq("group:home")
    end
  end

  describe "chore dreams" do
    it "is on until the owner switches it off" do
      expect(thread.chore_dreams?).to be(true)

      post "/byte/board/chore_dreams", params: { conversation_id: thread.id, on: false }

      expect(response.parsed_body["chore_dreams"]).to be(false)
      expect(thread.reload.chore_dreams?).to be(false)
      get "/board/#{thread.id}"
      expect(response.body).to include('data-board-chore-dreams="false"')
    end
  end

  describe "reserved groups" do
    it "settles the Whisper feed group even though nothing is tagged with it" do
      patch "/byte/board/tag", params: { conversation_id: thread.id, tag: "Whisper" }

      expect(response).to have_http_status(:ok)
      expect(thread.reload.chore_tags).to eq(["Whisper"])
    end

    it "shows every chore for an All board, and no routines or buttons" do
      thread.update!(metadata: thread.metadata.merge("chore_tags" => ["All"]))
      create(:chore, created_by_user: user, name: "Vacuum", tags: ["Home"], marked_due_at: Time.current)
      create(:chore, created_by_user: user, name: "Taxes", tags: ["Admin"], marked_due_at: Time.current)
      create(:chore, created_by_user: user, name: "Untagged", tags: [], marked_due_at: Time.current)
      routine!(name: "Focus mode", tag: "Work")

      get "/board/#{thread.id}"

      expect(board_items.pluck("kind").uniq).to eq(["chore"])
      expect(board_items.pluck("name")).to contain_exactly("Vacuum", "Taxes", "Untagged")
    end

    it "still brings a named group's routines alongside All's chores" do
      thread.update!(metadata: thread.metadata.merge("chore_tags" => ["All", "Work"]))
      create(:chore, created_by_user: user, name: "Vacuum", tags: ["Home"], marked_due_at: Time.current)
      routine!(name: "Focus mode", tag: "Work")

      get "/board/#{thread.id}"

      expect(board_items.pluck("kind")).to include("trigger")
      expect(board_items.select { |i| i["kind"] == "chore" }.pluck("name")).to include("Vacuum")
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

  # Task buttons — a board button that RUNS a Jil task on a press (the Whisper
  # fed/quiet/nap/gone controls), beside the chores and credit buttons.
  describe "task buttons" do
    let(:task) {
      Task.create!(user: user, name: "Whisper Fed", listener: "monitor::whisper-btn-fed", code: "// noop", enabled: true)
    }
    let!(:button) {
      BoardTaskButton.create!(user: user, task: task, label: "Fed", icon: "🍖", color: "#8B5E34", tags: ["Whisper"])
    }

    it "sits on a board watching its group, carrying its icon" do
      thread.update!(metadata: thread.metadata.merge("chore_tags" => ["Whisper"]))

      get "/board/#{thread.id}"

      item = board_items.find { |i| i["kind"] == "task" }
      expect(item).to be_present
      expect(item["name"]).to eq("Fed")
      expect(item["icon"]).to eq("🍖")
      expect(item["icon_kind"]).to eq("emoji")
    end

    it "runs its task with execute:true as the task's owner on a press" do
      allow(Jil::Executor).to receive(:async_call)

      post "/byte/board/tasks/#{button.id}/press"

      expect(response).to have_http_status(:ok)
      expect(Jil::Executor).to have_received(:async_call).with(
        user, task.code, { "execute" => true }, hash_including(task: task, auth: :run, auth_id: user.id)
      )
    end

    it "404s pressing someone else's button" do
      theirs = create(:user)
      their_task = Task.create!(user: theirs, name: "T", listener: "tell:x", code: "// noop")
      their_button = BoardTaskButton.create!(user: theirs, task: their_task, label: "X", tags: ["Whisper"])

      post "/byte/board/tasks/#{their_button.id}/press"

      expect(response).to have_http_status(:not_found)
    end
  end

  # A board installs under its own pet and reopens to itself.
  describe "GET /board/:id/manifest.webmanifest" do
    it "names the board, carries its pet's icon, and starts at this board" do
      thread.update!(name: "Desk", buddy_theme: "bloom")

      get "/board/#{thread.id}/manifest.webmanifest"

      expect(response).to have_http_status(:ok)
      manifest = JSON.parse(response.body)
      expect(manifest["name"]).to eq("Desk")
      expect(manifest["start_url"]).to eq("/board/#{thread.id}?source=pwa")
      expect(manifest["icons"].first["src"]).to eq("/bloom_favicon/web-app-manifest-192x192.png")
    end
  end

  # A standing alert on the board's group that names the face its pet holds.
  def gate_alert!
    BuddyAlert.create!(
      user: user, byte_conversation: thread, key: "laundry_gate", body: "The gate is open",
      raised_at: Time.current, last_raised_at: Time.current,
      metadata: { "groups" => ["Laundry"], "expression" => "pounce" },
    )
  end

  # The gallery of boards. Each card wears the face its board's pet is wearing,
  # and is only a way in: naming and sharing a board are done on the board.
  describe "GET /board (index)" do
    it "carries the data its face-swap reads and no management controls" do
      thread.update!(name: "Desk", buddy_theme: "bloom")

      get byte_board_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("data-board-index")
      expect(response.body).to include("data-buddy-themes")
      expect(response.body).to include("data-conversation-id=\"#{thread.id}\"")
      expect(response.body).not_to include("data-board-rename")
      expect(response.body).not_to include("data-board-share")
    end

    it "paints the face the board is holding over its mood" do
      thread.update!(
        buddy_theme: "bloom", buddy_expression: "neutral",
        metadata: thread.metadata.merge("chore_tags" => ["Laundry"]),
      )
      gate_alert!

      get byte_board_path

      expect(response.body).to include('data-held-expression="pounce"')
      expect(response.body).to include("face_pounce")
    end
  end

  describe "board settings on the board" do
    it "offers the owner rename and sharing" do
      get "/board/#{thread.id}"

      expect(response.body).to include("data-board-settings")
      expect(response.body).to include("data-board-rename-form")
      expect(response.body).to include("data-url=\"#{byte_conversation_path(thread)}\"")
      expect(response.body).to include("data-board-share")
    end

    it "opens holding the face a standing alert names" do
      thread.update!(buddy_theme: "bloom", metadata: thread.metadata.merge("chore_tags" => ["Laundry"]))
      gate_alert!

      get "/board/#{thread.id}"

      expect(response.body).to include('data-buddy-expression="pounce"')
    end
  end

  # Shared boards: a board its owner has opened to the household. A member can
  # open it and act on it - their tap crediting them, the work running with the
  # owner's reach - but it stays the owner's to manage, and an unshared board is
  # nobody else's business.
  describe "sharing with the household" do
    let!(:housemate) { create(:user, chore_household_id: user.chore_household_id) }

    # Byte access is a separate, id-based gate (me/Chelsea/Eve) from household
    # membership; the people who actually share boards all have it. Granting it
    # here keeps these examples about sharing rather than that gate.
    before { allow_any_instance_of(User).to receive(:byte_access?).and_return(true) }

    # The file-level `before` already signed the owner in, and you can't log in
    # over a live session (unauthorize_user blocks it), so drop it first.
    def sign_in_as(account)
      delete logout_path
      account.update!(password: "password123", password_confirmation: "password123")
      host! "byte.example.com"
      post login_path, params: { user: { username: account.username, password: "password123" } }
    end

    it "lets a housemate open a shared board" do
      thread.update!(metadata: thread.metadata.merge("shared" => true))
      sign_in_as(housemate)

      get "/board/#{thread.id}"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-board="true"')
    end

    it "keeps a housemate out of an unshared board" do
      sign_in_as(housemate)

      get "/board/#{thread.id}"

      expect(response).to redirect_to(byte_board_path)
    end

    it "lists a shared board on a housemate's index, not an unshared one" do
      shared = user.byte_conversations.create!(
        mode: :buddy, name: "Kitchen", last_message_at: Time.current,
        metadata: { "board" => true, "shared" => true },
      )
      sign_in_as(housemate)

      get byte_board_path

      expect(response.body).to include("data-conversation-id=\"#{shared.id}\"")
      expect(response.body).not_to include("data-conversation-id=\"#{thread.id}\"")
    end

    it "shows the OWNER's content on a shared board, whoever opens it" do
      thread.update!(metadata: thread.metadata.merge("chore_tags" => ["Whisper"], "shared" => true))
      task = Task.create!(user: user, name: "Fed", listener: "monitor::x", code: "// noop", enabled: true)
      BoardTaskButton.create!(user: user, task: task, label: "Fed", tags: ["Whisper"])
      sign_in_as(housemate)

      get "/board/#{thread.id}"

      expect(board_items.find { |i| i["kind"] == "task" }&.dig("name")).to eq("Fed")
    end

    it "runs a shared board's task button as the owner, crediting the presser" do
      thread.update!(metadata: thread.metadata.merge("chore_tags" => ["Whisper"], "shared" => true))
      task = Task.create!(user: user, name: "Fed", listener: "monitor::x", code: "// noop", enabled: true)
      button = BoardTaskButton.create!(user: user, task: task, label: "Fed", tags: ["Whisper"])
      sign_in_as(housemate)
      allow(Jil::Executor).to receive(:async_call)

      post "/byte/board/tasks/#{button.id}/press"

      expect(response).to have_http_status(:ok)
      expect(Jil::Executor).to have_received(:async_call).with(
        user, task.code, { "execute" => true },
        hash_including(task: task, auth: :run, auth_id: housemate.id)
      )
    end

    it "lets only the owner toggle sharing" do
      post "/byte/board/shared", params: { conversation_id: thread.id, shared: true }
      expect(response).to have_http_status(:ok)
      expect(thread.reload.shared?).to be(true)

      sign_in_as(housemate)
      post "/byte/board/shared", params: { conversation_id: thread.id, shared: false }
      expect(response).to have_http_status(:not_found)
      expect(thread.reload.shared?).to be(true)
    end
  end

  # Whose chores a board shows. The default is the owner's own; a board can be
  # set to show chosen members' chores instead — "the general household chores
  # and the ones assigned to Chelsea, not mine" — reaching past what the owner
  # would normally see.
  describe "whose chores a board shows" do
    let!(:housemate) { create(:user, chore_household_id: user.chore_household_id) }

    before { thread.update!(metadata: thread.metadata.merge("chore_tags" => ["Chores"])) }

    def chore_for(assignee, name, **attrs)
      create(
        :chore, created_by_user: user, chore_household_id: user.chore_household_id,
        name: name, tags: ["Chores"], marked_due_at: Time.current,
        assigned_to_user: assignee, **attrs
      )
    end

    def board_chore_names
      get "/board/#{thread.id}"
      board_items.select { |i| i["kind"] == "chore" }.pluck("name")
    end

    it "defaults to the owner's own, not a housemate's" do
      chore_for(user, "Mine")
      chore_for(housemate, "Theirs", sharing_mode: :personal)

      names = board_chore_names
      expect(names).to include("Mine")
      expect(names).not_to include("Theirs")
    end

    it "can show a housemate's chores and the general ones, not your own" do
      thread.update!(metadata: thread.metadata.merge("board_members" => [housemate.id]))
      chore_for(user, "Mine")
      chore_for(housemate, "Theirs", sharing_mode: :personal)
      create(
        :chore, created_by_user: user, chore_household_id: user.chore_household_id,
        name: "General", tags: ["Chores"], marked_due_at: Time.current
      )

      names = board_chore_names
      expect(names).to include("Theirs") # the housemate's, though it's personal
      expect(names).to include("General") # unassigned, shown whoever the board is for
      expect(names).not_to include("Mine") # the owner's own, dropped
    end

    it "offers the owner a member picker, confined to the household" do
      get "/board/#{thread.id}"

      expect(response.body).to include("data-board-members-section")
      expect(response.body).to include("value=\"#{housemate.id}\"")
    end
  end
end
