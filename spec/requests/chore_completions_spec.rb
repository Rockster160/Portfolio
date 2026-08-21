require "rails_helper"

RSpec.describe "ChoreCompletions", type: :request do
  # Covers the queue-first idempotency guarantees on the chore completion
  # endpoints. The client write-ahead queue can replay POST/DELETE if the
  # original response never made it back (page suspended, network died,
  # etc.) — the server must dedupe by client_mutation_id so a replay is a
  # no-op rather than a double-completion or wrong-row-deleted.
  describe "idempotency" do
    let(:user) { create(:user) }
    let(:chore) { create(:chore, created_by_user: user, name: "Brush", reward_pebbles: 5) }

    before { post login_path, params: { user: { username: user.username, password: "password123" } } }

    describe "POST create" do
      let(:mid) { SecureRandom.uuid }

      it "stores client_mutation_id and dedupes a replayed POST" do
        expect {
          post "/chores/items/#{chore.id}/completion",
            params:  { client_mutation_id: mid }.to_json,
            headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
        }.to change(ChoreCompletion, :count).by(1)
        expect(response).to have_http_status(:created)
        first = JSON.parse(response.body)
        expect(first["paid"]).to eq(5)
        expect(ChoreCompletion.last.client_mutation_id).to eq(mid)

        # Replay — same body, same mutation_id. Server must return the
        # prior completion's payload without creating a second row or
        # double-paying.
        expect {
          post "/chores/items/#{chore.id}/completion",
            params:  { client_mutation_id: mid }.to_json,
            headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
        }.not_to change(ChoreCompletion, :count)
        expect(response).to have_http_status(:ok)
        replay = JSON.parse(response.body)
        expect(replay["deduped"]).to be true
        expect(replay["paid"]).to eq(5)
      end

      it "still works without a client_mutation_id (legacy/direct call)" do
        expect {
          post "/chores/items/#{chore.id}/completion",
            params:  {}.to_json,
            headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
        }.to change(ChoreCompletion, :count).by(1)
        expect(response).to have_http_status(:created)
        expect(ChoreCompletion.last.client_mutation_id).to be_nil
      end
    end

    describe "DELETE destroy_last_today" do
      let(:mid) { SecureRandom.uuid }

      it "deletes the targeted completion when target_client_mutation_id is given" do
        post "/chores/items/#{chore.id}/completion",
          params:  { client_mutation_id: mid }.to_json,
          headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
        expect(ChoreCompletion.count).to eq(1)

        expect {
          delete "/chores/items/#{chore.id}/completion",
            params:  { target_client_mutation_id: mid }.to_json,
            headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
        }.to change(ChoreCompletion, :count).by(-1)
        expect(response).to have_http_status(:ok)
      end

      it "returns deduped=true (200, no error) when the target is already gone" do
        # Simulates a queued DELETE that already flushed once successfully
        # but the response was lost; queue retries. Server must NOT 404 and
        # must NOT delete some other completion as collateral.
        expect {
          delete "/chores/items/#{chore.id}/completion",
            params:  { target_client_mutation_id: SecureRandom.uuid }.to_json,
            headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
        }.not_to change(ChoreCompletion, :count)
        expect(response).to have_http_status(:ok)
        expect(JSON.parse(response.body)["deduped"]).to be true
      end

      it "does NOT delete a sibling completion when targeted id is gone" do
        # A queued undo for id X1 replays after the user has done a fresh
        # complete X2. The replay must target X1 (gone) and leave X2 alone.
        sibling = create(:chore_completion, chore: chore, user: user, paid_pebbles: 5)

        expect {
          delete "/chores/items/#{chore.id}/completion",
            params:  { target_client_mutation_id: SecureRandom.uuid }.to_json,
            headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
        }.not_to change(ChoreCompletion, :count)
        expect(ChoreCompletion.exists?(sibling.id)).to be true
      end

      it "falls back to most-recent-today when no target is given" do
        create(:chore_completion, chore: chore, user: user, paid_pebbles: 5)
        expect {
          delete "/chores/items/#{chore.id}/completion",
            params:  {}.to_json,
            headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
        }.to change(ChoreCompletion, :count).by(-1)
        expect(response).to have_http_status(:ok)
      end
    end

    describe "unique index" do
      it "rejects two completions with the same client_mutation_id for the same user" do
        mid = SecureRandom.uuid
        create(:chore_completion, chore: chore, user: user, client_mutation_id: mid)
        expect {
          create(:chore_completion, chore: chore, user: user, client_mutation_id: mid)
        }.to raise_error(ActiveRecord::RecordNotUnique)
      end

      it "allows multiple completions with NULL client_mutation_id" do
        expect {
          create(:chore_completion, chore: chore, user: user, client_mutation_id: nil)
          create(:chore_completion, chore: chore, user: user, client_mutation_id: nil)
        }.not_to raise_error
      end
    end
  end

  # Completing an anchor is what makes its `:after_chore` followers due —
  # "Go get mail" done today puts "Go through mail" on Today. The follower
  # gets no completion row and no `updated_at` bump of its own, so nothing
  # about the write tells a connected client to look at it.
  #
  # `/chores/sync` already handles that (ChoresController#after_chore_follower_ids),
  # but it only runs on a full sync — page boot, foreground, reconnect, 4am.
  # On a page left open the card didn't appear for hours. These cover the two
  # channels that fire immediately: the tap response (the acting device's ONLY
  # channel — ChoreBroadcaster skips the actor's own tab) and the broadcast
  # `chore_ids` every other device re-fetches /state for.
  describe "after_chore followers" do
    let(:owner) { create(:user) }
    let(:partner) { create(:user) }
    let!(:household) { share_chore_household!(owner, partner) }

    let!(:anchor) {
      create(
        :chore,
        created_by_user: owner, chore_household: household, name: "Go get mail",
        sharing_mode: :household, recurrence: { "freq" => "weekly", "by_day" => ["tue"] }
      )
    }
    let!(:follower) {
      create(
        :chore,
        created_by_user: owner, chore_household: household, name: "Go through mail",
        assigned_to_user: owner,
        recurrence: {
          "freq" => "after_chore", "unit" => "day", "interval" => 0, "anchor_chore_id" => anchor.id
        }
      )
    }

    before do
      owner.reload
      partner.reload
      post login_path, params: { user: { username: owner.username, password: "password123" } }
    end

    def tap_chore(chore, params={})
      post "/chores/items/#{chore.id}/completion",
        params:  params.to_json,
        headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
    end

    def undo_chore(chore, params={})
      delete "/chores/items/#{chore.id}/completion",
        params:  params.to_json,
        headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
    end

    it "ships the newly-due follower in the tap response" do
      tap_chore(anchor)

      expect(response.parsed_body.dig("chore", "id")).to eq(anchor.id)
      followers = response.parsed_body["chores"]
      expect(followers.pluck("id")).to eq([follower.id])
      expect(followers.first["today_visible"]).to be(true)
      expect(followers.first["due_today"]).to be(true)
    end

    it "ships the follower again on undo so it comes back off Today" do
      tap_chore(anchor)
      undo_chore(anchor)

      followers = response.parsed_body["chores"]
      expect(followers.pluck("id")).to eq([follower.id])
      expect(followers.first["today_visible"]).to be(false)
    end

    it "names the follower in the broadcast so other devices re-fetch it" do
      payloads = []
      allow(MonitorChannel).to receive(:broadcast_to) { |_user, payload| payloads << payload }

      tap_chore(anchor)

      ids = payloads.filter_map { |p| p.dig(:data, :chore_ids) }.flatten.uniq
      expect(ids).to include(anchor.id, follower.id)
    end

    it "leaves `chores` empty for a chore nothing follows" do
      plain = create(:chore, created_by_user: owner, chore_household: household, name: "Dishes")
      tap_chore(plain)

      expect(response.parsed_body["chores"]).to eq([])
    end

    # A container tap is recorded against the leaf, so the leaf's id is what
    # reaches `response_payload` — a follower anchored on the PARENT has to
    # resolve from the leaf's `parent_chore_id` or it goes missing on exactly
    # the taps the user actually makes.
    context "when the anchor is a per-person container" do
      let!(:container) {
        create(
          :chore,
          created_by_user: owner, chore_household: household, name: "Laundry",
          show_on_today_view: :never
        )
      }
      let!(:my_half) {
        create(
          :chore,
          created_by_user: owner, chore_household: household, name: "Laundry",
          parent_chore: container, assigned_to_user: owner
        )
      }
      let!(:fold) {
        create(
          :chore,
          created_by_user: owner, chore_household: household, name: "Fold Laundry",
          assigned_to_user: owner,
          recurrence: {
            "freq"            => "after_chore",
            "unit"            => "day",
            "interval"        => 0,
            "anchor_chore_id" => container.id,
          }
        )
      }

      it "resolves the parent-anchored follower from the leaf the tap landed on" do
        tap_chore(container)

        expect(response.parsed_body.dig("chore", "id")).to eq(my_half.id)
        expect(response.parsed_body["chores"].pluck("id")).to eq([fold.id])
      end
    end

    # The follower is personal + assigned, so it's invisible to the partner.
    # `accessible_chores` is what keeps it out of their payload.
    it "never leaks a follower the viewer can't see" do
      delete logout_path
      post login_path, params: { user: { username: partner.username, password: "password123" } }
      tap_chore(anchor)

      expect(response.parsed_body["chores"]).to eq([])
    end
  end

  # Tapping a chore that's been split into per-person sub-chores.
  #
  # The container is the card people actually see: the Hot strip shows the
  # PICK, and picks land on the parent (a `hot_eligibility: never` sub is
  # rejected outright, an unscheduled container survives). Tapping it used to
  # write a completion against the family, which credits neither half — the
  # person's own card stayed unticked and the schedule under it never moved.
  describe "tapping a per-person container chore" do
    let(:owner) { create(:user) }
    let(:household) { create(:chore_household, owner_user: owner) }
    let(:partner) { create(:user) }
    let!(:partner_membership) {
      create(:chore_household_membership, chore_household: household, user: partner, role: :member)
    }

    let!(:parent) {
      create(
        :chore,
        created_by_user: owner, chore_household: household, name: "Shower",
        show_on_today_view: :never, reward_pebbles: 4
      )
    }
    let!(:mine) {
      create(
        :chore,
        created_by_user: owner, chore_household: household, name: "Shower",
        parent_chore: parent, assigned_to_user: owner, reward_pebbles: 4
      )
    }
    let!(:theirs) {
      create(
        :chore,
        created_by_user: partner, chore_household: household, name: "Shower",
        parent_chore: parent, assigned_to_user: partner, reward_pebbles: 4
      )
    }

    before do
      owner.reload
      partner.reload
      post login_path, params: { user: { username: owner.username, password: "password123" } }
    end

    def tap_chore(chore, params={})
      post "/chores/items/#{chore.id}/completion",
        params:  params.to_json,
        headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
    end

    def undo_chore(chore, params={})
      delete "/chores/items/#{chore.id}/completion",
        params:  params.to_json,
        headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
    end

    it "records the tapper's own sub-chore, not the container" do
      expect { tap_chore(parent) }.to change(ChoreCompletion, :count).by(1)

      completion = ChoreCompletion.last
      expect(completion.chore_id).to eq(mine.id)
      expect(completion.parent_chore_id).to eq(parent.id)
      expect(completion.user_id).to eq(owner.id)
      expect(theirs.chore_completions).to be_empty
      # The response carries the sub-chore so the card that was unticked is
      # the one the client hears about.
      expect(response.parsed_body.dig("chore", "id")).to eq(mine.id)
    end

    it "pays the container's hot multiplier on the redirected tap" do
      create(:chore_hot_pick, chore: parent, multiplier: 2.0, day_key: ChoreDay.current(owner))
      tap_chore(parent)

      completion = ChoreCompletion.last
      expect(completion.hot_multiplier).to eq(2.0)
      expect(completion.paid_pebbles).to eq(8) # sub's 4 reward × the parent's pick
    end

    it "still advances the container's streak" do
      tap_chore(parent)

      expect(ChoreStreak.find_by(user_id: owner.id, chore_id: parent.id)&.current_streak).to eq(1)
      expect(ChoreStreak.find_by(user_id: owner.id, chore_id: mine.id)).to be_nil
    end

    it "undoes a container tap even without the mutation id to target" do
      tap_chore(parent)
      expect { undo_chore(parent) }.to change(ChoreCompletion, :count).by(-1)
      expect(response).to have_http_status(:ok)
      expect(mine.chore_completions).to be_empty
    end

    it "undoes a container tap by the mutation id the client kept" do
      tap_chore(parent, client_mutation_id: "abc-123")
      expect { undo_chore(parent, target_client_mutation_id: "abc-123") }
        .to change(ChoreCompletion, :count).by(-1)
      expect(response.parsed_body.dig("chore", "id")).to eq(mine.id)
    end

    it "credits the named member's own sub-chore when completing on their behalf" do
      post "/chores/items/#{parent.id}/anonymous_completion",
        params:  { credit_user_id: partner.id }.to_json,
        headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

      completion = ChoreCompletion.last
      expect(completion.chore_id).to eq(theirs.id)
      expect(completion.user_id).to eq(partner.id)
    end

    # Nobody is named on an anonymous completion, so there's no whose-sub to
    # answer. It stays on the container, where it still counts for the
    # family's cooldown and carryover.
    it "leaves a truly anonymous completion on the container" do
      post "/chores/items/#{parent.id}/anonymous_completion",
        params:  { credit_user_id: "" }.to_json,
        headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

      expect(ChoreCompletion.last.chore_id).to eq(parent.id)
    end

    # The narrow half of the rule: a parent whose children are per-item
    # rather than per-person is a thing people tap on purpose.
    context "when the children are per item rather than per person" do
      let!(:supplements) {
        create(:chore, created_by_user: owner, chore_household: household, name: "Supplements", reward_pebbles: 2)
      }
      let!(:focus_med) {
        create(
          :chore, created_by_user: owner, chore_household: household, name: "Focus",
          parent_chore: supplements, assigned_to_user: owner, reward_pebbles: 2
        )
      }
      let!(:cymbalta) {
        create(
          :chore, created_by_user: owner, chore_household: household, name: "Cymbalta",
          parent_chore: supplements, assigned_to_user: owner, reward_pebbles: 2
        )
      }

      it "honors the tap exactly and never guesses which child was meant" do
        tap_chore(supplements)

        expect(ChoreCompletion.last.chore_id).to eq(supplements.id)
        expect(focus_med.chore_completions).to be_empty
        expect(cymbalta.chore_completions).to be_empty
      end

      it "still records the leaf when the leaf itself is tapped" do
        tap_chore(cymbalta)

        expect(ChoreCompletion.last.chore_id).to eq(cymbalta.id)
      end
    end
  end

  # The anonymous-completion endpoint doubles as "complete on behalf of a
  # household member": when `credit_user_id` is present and belongs to the
  # recorder's household, the full ChoreCompleter pipeline runs under that
  # user's name (points, streak, Jil trigger). When it's blank or foreign,
  # the original anonymous flow runs.
  describe "credit_user_id" do
    let(:owner) { create(:user) }
    # Owner-user gets a manager membership automatically via the household model.
    let(:household) { create(:chore_household, owner_user: owner) }
    let(:member) { create(:user) }
    let!(:member_membership) { create(:chore_household_membership, chore_household: household, user: member, role: :member) }
    let(:outsider) { create(:user) }
    let(:chore) { create(:chore, created_by_user: owner, chore_household: household, reward_pebbles: 7) }

    before do
      owner.reload
      member.reload
      post login_path, params: { user: { username: owner.username, password: "password123" } }
    end

    def post_completion(params)
      post "/chores/items/#{chore.id}/anonymous_completion",
        params:  params.to_json,
        headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
    end

    context "with blank credit_user_id (anonymous branch)" do
      it "creates an anonymous, payout-skipped completion under the recorder" do
        expect { post_completion(credit_user_id: "") }
          .to change(ChoreCompletion, :count).by(1)
        expect(response).to have_http_status(:created)
        c = ChoreCompletion.last
        expect(c.anonymous).to be true
        expect(c.payout_skipped).to be true
        expect(c.paid_pebbles).to eq(0)
        expect(c.user_id).to eq(owner.id)
        body = JSON.parse(response.body)
        expect(body["anonymous"]).to be true
        expect(body["credited_to"]).to be_nil
      end
    end

    context "with credit_user_id of a household member" do
      it "runs ChoreCompleter under the credited user and pays them" do
        expect { post_completion(credit_user_id: member.id) }
          .to change(ChoreCompletion, :count).by(1)
        expect(response).to have_http_status(:created)
        c = ChoreCompletion.last
        expect(c.user_id).to eq(member.id)
        expect(c.anonymous).to be false
        expect(c.payout_skipped).to be false
        expect(c.paid_pebbles).to eq(7)
        body = JSON.parse(response.body)
        expect(body["credited_to"]).to eq({ "id" => member.id, "username" => member.username })
      end

      it "fires the Jil chore_completion trigger for the credited user" do
        # Ensure the chore exists before we start spying (its own
        # after_create_commit fires Jil.trigger and would otherwise pollute).
        chore
        allow(::Jil).to receive(:trigger)
        post_completion(credit_user_id: member.id)
        expect(::Jil).to have_received(:trigger).with(
          satisfy { |u| u.id == member.id },
          :chore_completion,
          satisfy { |payload| payload.is_a?(ChoreCompletion) && payload.execution_attrs[:action] == :completed },
        ).at_least(:once)
      end

      it "advances the credited user's streak, not the recorder's" do
        post_completion(credit_user_id: member.id)
        expect(ChoreStreak.find_by(user_id: member.id, chore_id: chore.id)&.current_streak).to eq(1)
        expect(ChoreStreak.find_by(user_id: owner.id, chore_id: chore.id)).to be_nil
      end
    end

    context "with credit_user_id outside the household" do
      it "silently falls back to anonymous rather than crediting the outsider" do
        expect { post_completion(credit_user_id: outsider.id) }
          .to change(ChoreCompletion, :count).by(1)
        c = ChoreCompletion.last
        expect(c.anonymous).to be true
        expect(c.user_id).to eq(owner.id)
        expect(c.paid_pebbles).to eq(0)
      end
    end
  end

  # History-modal payout toggle: a manager can flip a completion between
  # paid and skipped. `skipped_reason` is owned by the server (never sent
  # by the form) and a skipped completion always pays 0, since the balance
  # is a plain SUM(paid_pebbles).
  describe "payout_skipped toggle" do
    let(:owner) { create(:user) }
    let(:household) { create(:chore_household, owner_user: owner) }
    let(:chore) { create(:chore, created_by_user: owner, chore_household: household, reward_pebbles: 7) }
    let(:actor) { owner }

    before do
      actor.reload
      post login_path, params: { user: { username: actor.username, password: "password123" } }
    end

    def patch_completion(completion, attrs)
      patch "/chores/completions/#{completion.id}",
        params:  { chore_completion: attrs }.to_json,
        headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
    end

    def build_completion(**attrs)
      create(:chore_completion, { chore: chore, user: owner }.merge(attrs))
    end

    it "restores the payout on a skipped completion and clears the reason" do
      completion = build_completion(
        payout_skipped: true,
        skipped_reason: "Cooldown — resets at end of day",
        paid_pebbles:   0,
        base_pebbles:   7,
      )

      patch_completion(completion, payout_skipped: false, paid_pebbles: 7)

      expect(response).to have_http_status(:ok)
      completion.reload
      expect(completion.payout_skipped).to be false
      expect(completion.skipped_reason).to be_nil
      expect(completion.paid_pebbles).to eq(7)
    end

    it "skips a paid completion, zeroes the payout and stamps the reason" do
      completion = build_completion(payout_skipped: false, paid_pebbles: 7, base_pebbles: 7)

      patch_completion(completion, payout_skipped: true, paid_pebbles: 7)

      expect(response).to have_http_status(:ok)
      completion.reload
      expect(completion.payout_skipped).to be true
      expect(completion.paid_pebbles).to eq(0)
      expect(completion.skipped_reason).to eq("Skipped by hand")
    end

    it "leaves an existing reason alone when the flag does not move" do
      completion = build_completion(
        payout_skipped: true,
        skipped_reason: "Marked done by someone outside the household",
        paid_pebbles:   0,
      )

      patch_completion(completion, payout_skipped: true, note: "audited")

      expect(response).to have_http_status(:ok)
      completion.reload
      expect(completion.skipped_reason).to eq("Marked done by someone outside the household")
      expect(completion.note).to eq("audited")
    end

    it "rebuilds the streak when the flag flips" do
      completion = build_completion(payout_skipped: true, paid_pebbles: 0)
      expect(ChoreStreak).to receive(:rebuild_for!).with(owner, chore)

      patch_completion(completion, payout_skipped: false, paid_pebbles: 7)

      expect(response).to have_http_status(:ok)
    end

    context "when the actor is a plain household member" do
      let(:member) { create(:user) }
      let(:actor) { member }
      let!(:membership) {
        create(:chore_household_membership, chore_household: household, user: member, role: :member)
      }

      it "refuses the edit — members can't rewrite history" do
        completion = create(:chore_completion, chore: chore, user: member, payout_skipped: true, paid_pebbles: 0)

        patch_completion(completion, payout_skipped: false, paid_pebbles: 7)

        expect(response).to have_http_status(:forbidden)
        expect(completion.reload.payout_skipped).to be true
      end
    end
  end
end
