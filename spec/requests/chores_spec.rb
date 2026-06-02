require "rails_helper"

RSpec.describe "Chores", type: :request do
  let(:user) { create(:user) }
  before { post login_path, params: { user: { username: user.username, password: "password123" } } }

  it "GET /chores renders the grid" do
    create(:chore, created_by_user: user, name: "Brush Teeth", reward_pebbles: 1)
    get chores_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Brush Teeth")
    expect(response.body).to include("1p")
  end

  it "GET /chores/today renders today's view" do
    get chores_today_path
    expect(response).to have_http_status(:ok)
  end

  it "GET /chores/balance renders balance + goals" do
    create(:chore_goal, user: user, name: "Lego Set", target_value: 500)
    get chores_balance_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Lego Set")
  end

  describe "streak bonuses CRUD" do
    let(:chore) { create(:chore, created_by_user: user, name: "Brush", reward_pebbles: 1) }

    it "POST creates a streak bonus with normalized integer levels and returns html" do
      post "/chores/streak_bonuses",
        params: {
          chore_streak_bonus: {
            name:     "Streak Master",
            chore_id: chore.id,
            kind:     "chore_streak",
            config:   {
              levels: [
                { threshold: "3", multiplier: "2", bonus_pebbles: "1" },
                # Fractional input is floored to integer per the
                # "multipliers are always integers" rule.
                { threshold: "7", multiplier: "1.9", bonus_pebbles: "0" },
                { threshold: "", multiplier: "", bonus_pebbles: "" }, # empty row dropped
              ],
            },
          },
        }.to_json,
        headers: { "CONTENT_TYPE" => "application/json", "ACCEPT" => "application/json" }
      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body["html"]).to include("Streak Master")
      bonus = ChoreStreakBonus.find(body["id"])
      expect(bonus.config["levels"]).to eq([
        { "threshold" => 3, "multiplier" => 2, "bonus_pebbles" => 1 },
        { "threshold" => 7, "multiplier" => 1, "bonus_pebbles" => 0 },
      ])
    end

    it "POST drops chore_id when kind is a pebble-threshold (chore-agnostic)" do
      post "/chores/streak_bonuses",
        params: {
          chore_streak_bonus: {
            name:     "Daily 50",
            chore_id: chore.id, # client may post it; controller should ignore
            kind:     "daily_pebbles",
            config:   { levels: [{ threshold: "50", multiplier: "2", bonus_pebbles: "0" }] },
          },
        }.to_json,
        headers: { "CONTENT_TYPE" => "application/json", "ACCEPT" => "application/json" }
      expect(response).to have_http_status(:created)
      bonus = ChoreStreakBonus.find(JSON.parse(response.body)["id"])
      expect(bonus.chore_id).to be_nil
    end

    it "DELETE removes the streak bonus" do
      b = create(:chore_streak_bonus, user: user, chore: chore, kind: :chore_streak)
      delete "/chores/streak_bonuses/#{b.id}"
      expect(response).to have_http_status(:no_content)
      expect(ChoreStreakBonus.where(id: b.id)).to be_empty
    end
  end

  describe "goals CRUD (merged with former achievements)" do
    let(:chore) { create(:chore, created_by_user: user, name: "Water", reward_pebbles: 1) }

    it "POST creates a pebbles goal that defaults to relative-earned" do
      post "/chores/goals",
        params: {
          chore_goal: { name: "Lego Set", kind: "pebbles", target_value: 500 },
        }.to_json,
        headers: { "CONTENT_TYPE" => "application/json", "ACCEPT" => "application/json" }
      expect(response).to have_http_status(:created)
      goal = ChoreGoal.find(JSON.parse(response.body)["id"])
      expect(goal.scope_mode).to eq("relative")
      expect(goal.tracking_mode).to eq("earned")
      expect(goal.target_value).to eq(500)
    end

    it "POST creates a chore-streak goal with chore_id on the FK column" do
      post "/chores/goals",
        params: {
          chore_goal: {
            name:         "7-day Water",
            kind:         "chore_streak",
            target_value: 7,
            chore_id:     chore.id,
          },
        }.to_json,
        headers: { "CONTENT_TYPE" => "application/json", "ACCEPT" => "application/json" }
      expect(response).to have_http_status(:created)
      goal = ChoreGoal.find(JSON.parse(response.body)["id"])
      expect(goal.kind).to eq("chore_streak")
      expect(goal.chore_id).to eq(chore.id)
    end

    it "POST nulls chore_id when kind doesn't use it (stale form value defense)" do
      post "/chores/goals",
        params: {
          chore_goal: {
            name:         "Test",
            kind:         "total_completions",
            target_value: 5,
            chore_id:     chore.id, # stale from a prior kind selection
          },
        }.to_json,
        headers: { "CONTENT_TYPE" => "application/json", "ACCEPT" => "application/json" }
      expect(response).to have_http_status(:created)
      goal = ChoreGoal.find(JSON.parse(response.body)["id"])
      expect(goal.chore_id).to be_nil
    end

    it "POST relative chore_completions goal starts at 0/target even with prior completions" do
      create(:chore_completion, user: user, chore: chore)
      create(:chore_completion, user: user, chore: chore)
      post "/chores/goals",
        params: {
          chore_goal: {
            name:         "100 waters",
            kind:         "chore_completions",
            scope_mode:   "relative",
            target_value: 100,
            chore_id:     chore.id,
          },
        }.to_json,
        headers: { "CONTENT_TYPE" => "application/json", "ACCEPT" => "application/json" }
      expect(response).to have_http_status(:created)
      goal = ChoreGoal.find(JSON.parse(response.body)["id"])
      expect(goal.baseline_value).to eq(2)
      expect(goal.current_value).to eq(0)
    end

    it "DELETE archives the goal" do
      goal = create(:chore_goal, user: user, target_value: 50)
      delete "/chores/goals/#{goal.id}"
      expect(response).to have_http_status(:no_content)
      expect(goal.reload.archived_at).to be_present
    end
  end

  it "POST /chores/items creates a chore" do
    expect {
      post "/chores/items",
        params: { chore: { name: "Vacuum", reward_pebbles: 5, icon: "🧹" } }.to_json,
        headers: { "CONTENT_TYPE" => "application/json", "Accept" => "application/json" }
    }.to change(Chore, :count).by(1)
    expect(response).to have_http_status(:created)
  end

  it "POST /chores/items persists notes_template and serializes it back" do
    template = 'Fed Whisper {Food Type:Select [Beef, Chicken, "Turkey, Shredded"]} with {Kibble Ounces:Numeric}oz kibble'
    post "/chores/items",
      params: { chore: { name: "Feed Whisper", reward_pebbles: 1, notes_template: template } }.to_json,
      headers: { "CONTENT_TYPE" => "application/json", "Accept" => "application/json" }
    expect(response).to have_http_status(:created)
    body = JSON.parse(response.body)
    expect(body["chore"]["notes_template"]).to eq(template)
    expect(Chore.last.notes_template).to eq(template)
  end

  it "POST /chores/items/:id/completion creates a completion + updates balance" do
    chore = create(:chore, created_by_user: user, name: "Walk", reward_pebbles: 5)
    expect {
      post "/chores/items/#{chore.id}/completion",
        headers: { "Accept" => "application/json" }
    }.to change(ChoreCompletion, :count).by(1)
    body = JSON.parse(response.body)
    expect(body["balance"]).to eq(5)
    # Canonical chore JSON in response — ChoreStore upserts directly from this.
    expect(body["chore"]["done_count_today"]).to eq(1)
    expect(body["chore"]["last_completed_at"]).to be_present
  end

  it "POST /chores/items/:id/completion stores note + note_values from the body" do
    chore = create(:chore, created_by_user: user, name: "Feed Whisper", reward_pebbles: 1,
                   notes_template: 'Fed Whisper {Food Type} with {Kibble Ounces}oz kibble')
    post "/chores/items/#{chore.id}/completion",
      params: {
        chore_completion: {
          note: "Fed Whisper Beef with 6oz kibble",
          note_values: { "Food Type" => "Beef", "Kibble Ounces" => 6 },
        },
      }.to_json,
      headers: { "CONTENT_TYPE" => "application/json", "Accept" => "application/json" }
    expect(response).to have_http_status(:created)
    completion = ChoreCompletion.last
    expect(completion.note).to eq("Fed Whisper Beef with 6oz kibble")
    expect(completion.metadata["note_values"]).to eq({
      "Food Type" => "Beef",
      "Kibble Ounces" => 6,
    })
  end

  it "DELETE completion removes the most recent and updates balance" do
    chore = create(:chore, created_by_user: user, name: "Walk", reward_pebbles: 5)
    ChoreCompleter.new(chore, user).call
    expect(user.chore_balance).to eq(5)

    delete "/chores/items/#{chore.id}/completion", headers: { "Accept" => "application/json" }
    expect(response).to have_http_status(:ok)
    expect(user.reload.chore_balance).to eq(0)
  end

  it "GET /chores/history renders the JS shell (no server-rendered entries)" do
    chore = create(:chore, created_by_user: user, name: "Vacuum", reward_pebbles: 5)
    create(:chore_completion, chore: chore, user: user, paid_pebbles: 5)
    get chores_history_path
    expect(response).to have_http_status(:ok)
    # Shell contains the loading-state placeholder and the empty
    # containers JS will hydrate. Entries are NOT in the body — they're
    # fetched separately via /chores/history.json.
    expect(response.body).to include("Loading history")
    expect(response.body).to include("data-history-list")
    expect(response.body).to include("data-pending-section")
    expect(response.body).not_to include(">Vacuum<")
  end

  it "GET /chores/history.json returns entries + pagination shape" do
    chore = create(:chore, created_by_user: user, name: "Vacuum", reward_pebbles: 5)
    create(:chore_completion, chore: chore, user: user, paid_pebbles: 5)
    get "/chores/history.json", headers: { "Accept" => "application/json" }
    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body["entries"].size).to eq(1)
    entry = body["entries"].first
    expect(entry["kind"]).to eq("completion")
    expect(entry["chore"]["name"]).to eq("Vacuum")
    expect(entry["chore"]["icon_kind"]).to be_present
    expect(entry["when_label"]).to be_present
    expect(body["total_count"]).to eq(1)
    expect(body["total_pages"]).to eq(1)
    expect(body["from"]).to eq(1)
    expect(body["to"]).to eq(1)
  end

  it "PATCH /chores/completions/:id edits the amount and updates balance" do
    chore = create(:chore, created_by_user: user, reward_pebbles: 5)
    completion = create(:chore_completion, chore: chore, user: user, paid_pebbles: 5)
    patch "/chores/completions/#{completion.id}",
      params: { chore_completion: { paid_pebbles: 8 } }.to_json,
      headers: { "CONTENT_TYPE" => "application/json", "Accept" => "application/json" }
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)["balance"]).to eq(8)
    expect(completion.reload.paid_pebbles).to eq(8)
  end

  it "PATCH /chores/completions/:id stores hot_multiplier, streak_multiplier, and hot_pick flag verbatim" do
    chore = create(:chore, created_by_user: user, reward_pebbles: 5)
    completion = create(:chore_completion, chore: chore, user: user,
      paid_pebbles: 5, hot_multiplier: 1.0, streak_multiplier: 1.0, metadata: {})
    patch "/chores/completions/#{completion.id}",
      params: { chore_completion: { hot_multiplier: 2.0, streak_multiplier: 2.5, hot_pick: true } }.to_json,
      headers: { "CONTENT_TYPE" => "application/json", "Accept" => "application/json" }
    expect(response).to have_http_status(:ok)
    completion.reload
    # Multipliers are stored as historical record — not auto-applied
    # to paid_pebbles (which stays at its prior 5).
    expect(completion.hot_multiplier).to eq(2.0)
    expect(completion.streak_multiplier).to eq(2.5)
    expect(completion.metadata["hot_pick"]).to be(true)
    expect(completion.paid_pebbles).to eq(5)
  end

  it "PATCH preserves existing metadata keys when toggling hot_pick" do
    chore = create(:chore, created_by_user: user)
    completion = create(:chore_completion, chore: chore, user: user,
      metadata: { "imported_from" => "csv" })
    patch "/chores/completions/#{completion.id}",
      params: { chore_completion: { hot_pick: true } }.to_json,
      headers: { "CONTENT_TYPE" => "application/json", "Accept" => "application/json" }
    completion.reload
    expect(completion.metadata["hot_pick"]).to be(true)
    expect(completion.metadata["imported_from"]).to eq("csv")
  end

  it "PATCH /chores/completions/:id can change timestamp + note, day_key recomputes" do
    chore = create(:chore, created_by_user: user, reward_pebbles: 5)
    completion = create(:chore_completion, chore: chore, user: user, paid_pebbles: 5)
    new_time = Time.zone.local(2026, 4, 15, 14, 30, 0)
    patch "/chores/completions/#{completion.id}",
      params: { chore_completion: { completed_at: new_time.iso8601, note: "moved" } }.to_json,
      headers: { "CONTENT_TYPE" => "application/json", "Accept" => "application/json" }
    expect(response).to have_http_status(:ok)
    completion.reload
    expect(completion.completed_at.to_i).to eq(new_time.to_i)
    expect(completion.note).to eq("moved")
    expect(completion.day_key).to eq(ChoreDay.current(user, at: new_time))
  end

  it "GET /chores/history.json filters with `amount>N` across all three feeds" do
    chore_small = create(:chore, created_by_user: user, reward_pebbles: 1)
    chore_big   = create(:chore, created_by_user: user, reward_pebbles: 10)
    create(:chore_completion, chore: chore_small, user: user, paid_pebbles: 1, base_pebbles: 1)
    create(:chore_completion, chore: chore_big,   user: user, paid_pebbles: 10, base_pebbles: 10)
    create(:chore_withdrawal, user: user, amount_pebbles: 2, note: "small w")
    create(:chore_withdrawal, user: user, amount_pebbles: 9, note: "big w")

    get "/chores/history.json", params: { q: "amount>5" }, headers: { "Accept" => "application/json" }
    body = JSON.parse(response.body)
    amounts = body["entries"].map { |e| e["amount_pebbles"] || e["paid_pebbles"] }.compact.uniq.sort
    expect(amounts).to eq([9, 10])
  end

  it "GET /chores/history.json filters with .query (note + chore name + time)" do
    cat = create(:chore, created_by_user: user, name: "Brush kitty")
    dog = create(:chore, created_by_user: user, name: "Feed dog")
    create(:chore_completion, chore: cat, user: user, note: "morning",
      completed_at: 2.days.ago, day_key: 2.days.ago.to_date)
    create(:chore_completion, chore: dog, user: user, note: "evening",
      completed_at: 1.day.ago, day_key: 1.day.ago.to_date)

    get "/chores/history.json", params: { q: "kitty" }, headers: { "Accept" => "application/json" }
    names = JSON.parse(response.body)["entries"].map { |e| e.dig("chore", "name") }
    expect(names).to include("Brush kitty")
    expect(names).not_to include("Feed dog")

    get "/chores/history.json", params: { q: "notes:evening" }, headers: { "Accept" => "application/json" }
    names = JSON.parse(response.body)["entries"].map { |e| e.dig("chore", "name") }
    expect(names).to include("Feed dog")
    expect(names).not_to include("Brush kitty")
  end

  it "GET /chores/history.json reports per-page counts, page, window, total" do
    chore = create(:chore, created_by_user: user, name: "Walk")
    60.times { |i|
      create(:chore_completion, chore: chore, user: user,
        completed_at: i.hours.ago, day_key: ChoreDay.current(user))
    }
    get "/chores/history.json", headers: { "Accept" => "application/json" }
    body = JSON.parse(response.body)
    expect(body["page"]).to eq(1)
    expect(body["total_pages"]).to eq(2)
    expect(body["page_completions"]).to eq(50)
    expect(body["page_withdrawals"]).to eq(0)
    expect(body["from"]).to eq(1)
    expect(body["to"]).to eq(50)
    expect(body["total_count"]).to eq(60)
  end

  it "GET /chores/history.json mixes completions + withdrawals newest first" do
    chore = create(:chore, created_by_user: user, name: "Mix")
    create(:chore_completion, chore: chore, user: user, paid_pebbles: 3,
      completed_at: 2.hours.ago)
    create(:chore_withdrawal, user: user, amount_pebbles: 2, note: "candy")
    get "/chores/history.json", headers: { "Accept" => "application/json" }
    kinds = JSON.parse(response.body)["entries"].map { |e| e["kind"] }
    expect(kinds).to eq(["withdrawal", "completion"])
  end

  it "GET /chores/recent_history returns the latest 10 mixed entries" do
    chore = create(:chore, created_by_user: user, name: "Walk")
    12.times { |i|
      create(:chore_completion, chore: chore, user: user, paid_pebbles: 1,
        completed_at: (i + 1).hours.ago, day_key: ChoreDay.current(user))
    }
    create(:chore_withdrawal, user: user, amount_pebbles: 3, note: "snack")
    get "/chores/recent_history", headers: { "Accept" => "application/json" }
    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body["entries"].size).to eq(10)
    # Newest = the just-created withdrawal.
    expect(body["entries"].first["kind"]).to eq("withdrawal")
    expect(body["entries"].first["note"]).to eq("snack")
    expect(body["balance"]).to be_a(Integer)
  end

  # ----------------------------------------------------------------
  # Header pill contract: `today_earnings` is THE canonical number
  # behind the balance pill on every chores page. Every endpoint that
  # could conceivably drive a balance UI update MUST return it, even
  # when the action itself doesn't move it (withdrawals don't touch
  # today_earnings, but the client still funnels through the same
  # writer). These specs lock the contract so the next refactor
  # can't silently regress the pill back to lifetime balance.
  # ----------------------------------------------------------------

  describe "today_earnings is always returned" do
    let(:chore) { create(:chore, created_by_user: user, reward_pebbles: 7) }
    before do
      # Two paid completions today + one paid yesterday — today_earnings
      # should be 14 regardless of lifetime balance.
      create(:chore_completion, chore: chore, user: user, paid_pebbles: 7, day_key: ChoreDay.current(user))
      create(:chore_completion, chore: chore, user: user, paid_pebbles: 7, day_key: ChoreDay.current(user))
      create(:chore_completion, chore: chore, user: user, paid_pebbles: 7, day_key: ChoreDay.current(user) - 1)
    end

    it "POST /chores/items/:id/completion" do
      post "/chores/items/#{chore.id}/completion",
        headers: { "Accept" => "application/json" }
      body = JSON.parse(response.body)
      expect(body).to have_key("today_earnings")
      expect(body["today_earnings"]).to eq(user.reload.chore_completions.where(day_key: ChoreDay.current(user)).sum(:paid_pebbles))
      expect(body["today_earnings"]).not_to eq(body["balance"])
    end

    it "PATCH /chores/completions/:id" do
      completion = user.chore_completions.first
      patch "/chores/completions/#{completion.id}",
        params: { chore_completion: { note: "edit" } }.to_json,
        headers: { "CONTENT_TYPE" => "application/json", "Accept" => "application/json" }
      body = JSON.parse(response.body)
      expect(body).to have_key("today_earnings")
    end

    it "DELETE /chores/completions/:id" do
      completion = user.chore_completions.where(day_key: ChoreDay.current(user)).first
      pre = user.chore_completions.where(day_key: ChoreDay.current(user)).sum(:paid_pebbles)
      delete "/chores/completions/#{completion.id}", headers: { "Accept" => "application/json" }
      body = JSON.parse(response.body)
      expect(body).to have_key("today_earnings")
      # Today's pill drops by exactly the paid amount of the deleted row.
      expect(body["today_earnings"]).to eq(pre - completion.paid_pebbles)
    end

    it "POST /chores/withdrawals (lifetime moves, today_earnings does not)" do
      pre_today = user.chore_completions.where(day_key: ChoreDay.current(user)).sum(:paid_pebbles)
      post "/chores/withdrawals",
        params: { chore_withdrawal: { amount_pebbles: 1, note: "snack" } }.to_json,
        headers: { "CONTENT_TYPE" => "application/json", "Accept" => "application/json" }
      body = JSON.parse(response.body)
      expect(body).to have_key("today_earnings")
      expect(body["today_earnings"]).to eq(pre_today)
    end

    it "DELETE /chores/withdrawals/:id (lifetime moves, today_earnings does not)" do
      withdrawal = create(:chore_withdrawal, user: user, amount_pebbles: 5, note: "n")
      pre_today = user.chore_completions.where(day_key: ChoreDay.current(user)).sum(:paid_pebbles)
      delete "/chores/withdrawals/#{withdrawal.id}", headers: { "Accept" => "application/json" }
      body = JSON.parse(response.body)
      expect(body).to have_key("today_earnings")
      expect(body["today_earnings"]).to eq(pre_today)
    end

    it "GET /chores/history.json" do
      get "/chores/history.json", headers: { "Accept" => "application/json" }
      body = JSON.parse(response.body)
      expect(body).to have_key("today_earnings")
    end

    it "GET /chores/recent_history" do
      get "/chores/recent_history", headers: { "Accept" => "application/json" }
      body = JSON.parse(response.body)
      expect(body).to have_key("today_earnings")
    end
  end

  it "Balance page lifetime card uses [data-lifetime-balance], not [data-balance]" do
    create(:chore_completion, user: user, paid_pebbles: 5, day_key: ChoreDay.current(user))
    get chores_balance_path
    expect(response).to have_http_status(:ok)
    # The header pill (today_earnings) uses [data-balance]; the
    # in-card "Pebbles available" lifetime number must not.
    expect(response.body).to include("data-lifetime-balance")
    expect(response.body).not_to match(/balance-amount.*data-balance[^-]/)
  end

  it "GET /chores/sync lookahead emits all 7 days, even when no chores are scheduled" do
    # No scheduled chores → every day in the 7-day window is still
    # present as an empty array. Otherwise the client renders the
    # next non-empty day at the top and the user reads it as
    # "tomorrow."
    create(:chore, created_by_user: user, one_off: true, name: "today only")
    get "/chores/sync", headers: { "Accept" => "application/json" }
    body = JSON.parse(response.body)
    today = ChoreDay.current(user)
    expected_keys = ((today + 1)..(today + 7)).map(&:iso8601)
    expect(body["lookahead"].keys.sort).to eq(expected_keys.sort)
    expect(body["lookahead"].values).to all(eq([]))
  end

  describe "pebble transfers" do
    let(:recipient) { create(:user) }
    before do
      share_chore_household!(user, recipient)
      chore = create(:chore, created_by_user: user, reward_pebbles: 40)
      create(:chore_completion, chore: chore, user: user, paid_pebbles: 40, base_pebbles: 40,
             payout_skipped: false, day_key: ChoreDay.current(user) - 1)
    end

    it "POST /chores/transfers creates a transfer and moves balance both sides" do
      post "/chores/transfers",
        params: { chore_transfer: { to_user_id: recipient.id, amount_pebbles: 15, note: "lunch" } }.to_json,
        headers: { "CONTENT_TYPE" => "application/json", "Accept" => "application/json" }
      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body["amount_pebbles"]).to eq(15)
      expect(body["balance"]).to eq(25)
      expect(body).to have_key("today_earnings")
      expect(user.reload.chore_balance).to eq(25)
      expect(recipient.reload.chore_balance).to eq(15)
    end

    it "rejects a transfer exceeding sender balance" do
      post "/chores/transfers",
        params: { chore_transfer: { to_user_id: recipient.id, amount_pebbles: 999 } }.to_json,
        headers: { "CONTENT_TYPE" => "application/json", "Accept" => "application/json" }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["errors"]).to include(/exceeds your available balance/)
    end

    it "rejects a transfer to a non-household user" do
      stranger = create(:user)
      post "/chores/transfers",
        params: { chore_transfer: { to_user_id: stranger.id, amount_pebbles: 5 } }.to_json,
        headers: { "CONTENT_TYPE" => "application/json", "Accept" => "application/json" }
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "surfaces transfers in /chores/history.json with direction + counterparty" do
      create(:chore_transfer, from_user: user, to_user: recipient, amount_pebbles: 7, note: "n")
      create(:chore_transfer, from_user: recipient, to_user: user, amount_pebbles: 3, note: nil)
      get "/chores/history.json", headers: { "Accept" => "application/json" }
      body = JSON.parse(response.body)
      transfers = body["entries"].select { |e| e["kind"] == "transfer" }
      expect(transfers.map { |t| t["direction"] }.sort).to eq(%w[incoming outgoing])
      outgoing = transfers.find { |t| t["direction"] == "outgoing" }
      expect(outgoing["counterparty_username"]).to eq(recipient.username)
      expect(outgoing["amount_pebbles"]).to eq(7)
      expect(body["transfer_count"]).to eq(2)
      expect(body["page_transfers"]).to eq(2)
    end

    it "surfaces transfers in /chores/recent_history" do
      create(:chore_transfer, from_user: user, to_user: recipient, amount_pebbles: 4, note: "tip")
      get "/chores/recent_history", headers: { "Accept" => "application/json" }
      body = JSON.parse(response.body)
      kinds = body["entries"].map { |e| e["kind"] }
      expect(kinds).to include("transfer")
    end

    it "PATCH /chores/transfers/:id updates amount + note (sender only)" do
      transfer = create(:chore_transfer, from_user: user, to_user: recipient, amount_pebbles: 5, note: "old")
      patch "/chores/transfers/#{transfer.id}",
        params: { chore_transfer: { amount_pebbles: 8, note: "new" } }.to_json,
        headers: { "CONTENT_TYPE" => "application/json", "Accept" => "application/json" }
      expect(response).to have_http_status(:ok)
      transfer.reload
      expect(transfer.amount_pebbles).to eq(8)
      expect(transfer.note).to eq("new")
    end

    it "DELETE /chores/transfers/:id refunds both balances (sender only)" do
      transfer = create(:chore_transfer, from_user: user, to_user: recipient, amount_pebbles: 12)
      pre_sender = user.chore_balance
      pre_recipient = recipient.chore_balance
      delete "/chores/transfers/#{transfer.id}", headers: { "Accept" => "application/json" }
      expect(response).to have_http_status(:ok)
      expect(user.reload.chore_balance).to eq(pre_sender + 12)
      expect(recipient.reload.chore_balance).to eq(pre_recipient - 12)
    end

    it "PATCH/DELETE /chores/transfers/:id is forbidden for non-sender" do
      # Fund the recipient so they can BE a sender on a transfer back.
      ch = create(:chore, created_by_user: recipient, reward_pebbles: 10)
      create(:chore_completion, chore: ch, user: recipient, paid_pebbles: 10, base_pebbles: 10,
             payout_skipped: false, day_key: ChoreDay.current(recipient) - 1)
      transfer = create(:chore_transfer, from_user: recipient, to_user: user, amount_pebbles: 3)
      patch "/chores/transfers/#{transfer.id}",
        params: { chore_transfer: { amount_pebbles: 99 } }.to_json,
        headers: { "CONTENT_TYPE" => "application/json", "Accept" => "application/json" }
      expect(response).to have_http_status(:not_found)
      delete "/chores/transfers/#{transfer.id}", headers: { "Accept" => "application/json" }
      expect(response).to have_http_status(:not_found)
    end
  end

  it "PATCH /chores/withdrawals/:id updates amount + note" do
    withdrawal = create(:chore_withdrawal, user: user, amount_pebbles: 5, note: "x")
    patch "/chores/withdrawals/#{withdrawal.id}",
      params: { chore_withdrawal: { amount_pebbles: 7, note: "y" } }.to_json,
      headers: { "CONTENT_TYPE" => "application/json", "Accept" => "application/json" }
    expect(response).to have_http_status(:ok)
    withdrawal.reload
    expect(withdrawal.amount_pebbles).to eq(7)
    expect(withdrawal.note).to eq("y")
  end

  it "POST completion accepts overrides from an edited pending push" do
    chore = create(:chore, created_by_user: user, reward_pebbles: 5)
    when_at = Time.current.change(usec: 0) - 30.minutes
    post "/chores/items/#{chore.id}/completion",
      params: {
        client_completed_at: when_at.iso8601,
        chore_completion: {
          note: "from queue",
          hot_multiplier: 2.0,
          streak_multiplier: 2.5,
          hot_pick: true,
        },
      }.to_json,
      headers: { "CONTENT_TYPE" => "application/json", "Accept" => "application/json" }
    expect(response).to have_http_status(:created)
    completion = user.chore_completions.last
    # Multipliers are historical record — paid_pebbles still driven by
    # the completer (5 base × 1× combined).
    expect(completion.note).to eq("from queue")
    expect(completion.hot_multiplier).to eq(2.0)
    expect(completion.streak_multiplier).to eq(2.5)
    expect(completion.metadata["hot_pick"]).to be(true)
    expect(completion.paid_pebbles).to eq(5)
  end

  it "DELETE /chores/completions/:id removes and updates balance" do
    chore = create(:chore, created_by_user: user, reward_pebbles: 5)
    completion = create(:chore_completion, chore: chore, user: user, paid_pebbles: 5)
    delete "/chores/completions/#{completion.id}", headers: { "Accept" => "application/json" }
    expect(response).to have_http_status(:ok)
    expect(user.reload.chore_balance).to eq(0)
  end

  it "POST completion honours client_completed_at when provided" do
    chore = create(:chore, created_by_user: user, reward_pebbles: 5)
    when_at = Time.current.change(usec: 0) - 30.minutes
    post "/chores/items/#{chore.id}/completion",
      params: { client_completed_at: when_at.iso8601 }.to_json,
      headers: { "CONTENT_TYPE" => "application/json", "Accept" => "application/json" }
    expect(response).to have_http_status(:created)
    expect(user.chore_completions.last.completed_at.to_i).to eq(when_at.to_i)
  end

  it "POST completion accepts arbitrarily old client_completed_at (queue must never lose events)" do
    chore = create(:chore, created_by_user: user, reward_pebbles: 5)
    long_ago = 90.days.ago.change(usec: 0)
    post "/chores/items/#{chore.id}/completion",
      params: { client_completed_at: long_ago.iso8601 }.to_json,
      headers: { "CONTENT_TYPE" => "application/json", "Accept" => "application/json" }
    expect(response).to have_http_status(:created)
    expect(user.chore_completions.last.completed_at.to_i).to eq(long_ago.to_i)
  end

  it "GET /chores/csrf returns a fresh token + balance" do
    create(:chore_completion, user: user, paid_pebbles: 7)
    get "/chores/csrf", headers: { "Accept" => "application/json" }
    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body["token"]).to be_present
    expect(body["balance"]).to eq(7)
  end

  it "GET /chores/items/:id/state returns canonical chore JSON + server_ts" do
    chore = create(:chore, created_by_user: user, reward_pebbles: 4)
    create(:chore_completion, chore: chore, user: user, paid_pebbles: 4)
    get "/chores/items/#{chore.id}/state", headers: { "Accept" => "application/json" }
    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body["chore"]["id"]).to eq(chore.id)
    expect(body["chore"]["done_count_today"]).to eq(1)
    expect(body["chore"]["last_completed_at"]).to be_present
    expect(body["chore"]["today_visible"]).to be(true).or be(false)
    expect(body["server_ts"]).to be_present
  end

  it "editing a completion today → yesterday recomputes cooldown, today_visible, streak, sync visibility" do
    chore = create(:chore, created_by_user: user, name: "Spray", reward_pebbles: 3,
                           threshold_seconds: 6 * 3600,
                           show_on_daily_view: :when_available,
                           recurrence: { freq: :never })
    travel_to Time.zone.local(2026, 4, 15, 14, 0, 0) do
      result = ChoreCompleter.new(chore, user).call
      completion = result.completion
      # Before the edit: completed today → today_visible via frozen
      # layout, cooldown still ticking.
      pre = ChoreSerializer.new(chore, viewer: user).as_json
      expect(pre[:done_count_today]).to eq(1)
      expect(pre[:today_visible]).to be(true)

      since_ts = Time.current
      travel 30.minutes
      yesterday = Time.current - 1.day

      patch "/chores/completions/#{completion.id}",
        params: { chore_completion: { completed_at: yesterday.iso8601 } }.to_json,
        headers: { "CONTENT_TYPE" => "application/json", "Accept" => "application/json" }
      expect(response).to have_http_status(:ok)

      # Response payload's canonical chore JSON reflects the edit.
      body = JSON.parse(response.body)
      expect(body["chore"]["done_count_today"]).to eq(0)
      # Cooldown elapsed (yesterday 2pm + 6h was long ago) — for
      # `when_available` the card stays today_visible: true.
      expect(body["chore"]["today_visible"]).to be(true)

      # Streak rebuilt: day_key moved to yesterday's chore-day.
      streak = ChoreStreak.find_by(user_id: user.id, chore_id: chore.id)
      expect(streak.last_completed_day).to eq(ChoreDay.current(user, at: yesterday))

      # Sync's incremental filter catches the backwards-moved edit
      # via updated_at, not just completed_at.
      get "/chores/sync?since=#{since_ts.iso8601}",
        headers: { "Accept" => "application/json" }
      sync = JSON.parse(response.body)
      expect(sync["chores"].map { |c| c["id"] }).to include(chore.id)
    end
  end

  it "GET /chores/sync ignores a `since` from a prior chore-day and returns the full set" do
    # Cross-day rollover: hot picks rotate, today_visible flips,
    # done_count_today resets. A naïve `since`-filtered diff would
    # leave yesterday's hot-strip lingering on the client.
    untouched_yesterday = create(:chore, created_by_user: user, name: "Untouched")

    travel_to Time.zone.local(2026, 4, 15, 12, 0, 0) do
      get "/chores/sync?since=#{(Time.current - 1.day).iso8601}",
          headers: { "Accept" => "application/json" }
      body = JSON.parse(response.body)
      ids = body["chores"].map { |c| c["id"] }
      # Without the cross-day fix, the untouched chore would be
      # filtered out (no updated_at change, no completions in window).
      expect(ids).to include(untouched_yesterday.id)
    end
  end

  it "GET /chores/sync returns canonical chore JSON for changed chores" do
    keeper = create(:chore, created_by_user: user, name: "Vacuum")
    archived = create(:chore, created_by_user: user, name: "Old", archived_at: 1.hour.ago)
    create(:chore_completion, chore: keeper, user: user, paid_pebbles: 3)

    get "/chores/sync", headers: { "Accept" => "application/json" }
    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body["server_ts"]).to be_present
    expect(body["balance"]).to be_a(Integer)
    ids = body["chores"].map { |c| c["id"] }
    expect(ids).to include(keeper.id)
    expect(body["archived_chore_ids"]).to include(archived.id)
    keeper_payload = body["chores"].find { |c| c["id"] == keeper.id }
    expect(keeper_payload["name"]).to eq("Vacuum")
    expect(keeper_payload["icon_kind"]).to be_present
  end

  it "POST /chores/items accepts day-reset cooldown sentinel (-1)" do
    post "/chores/items",
      params: { chore: { name: "Brush", reward_pebbles: 1, threshold_seconds: -1 } }.to_json,
      headers: { "CONTENT_TYPE" => "application/json", "Accept" => "application/json" }
    expect(response).to have_http_status(:created)
    chore = Chore.order(:id).last
    expect(chore.threshold_seconds).to eq(-1)
    expect(chore.cooldown_until_day_reset?).to be(true)
  end

  it "day-reset cooldown blocks a second payout the same chore-day, allows after day flip" do
    # Pin time mid-morning so +5h doesn't cross the 4am cutoff and
    # split the test's "same chore-day" assumption.
    travel_to Time.zone.local(2026, 4, 15, 10, 0, 0) do
      chore = create(:chore, created_by_user: user, reward_pebbles: 5, threshold_seconds: -1)
      first  = ChoreCompleter.new(chore, user, at: Time.current).call
      expect(first.completion.payout_skipped).to be(false)
      second = ChoreCompleter.new(chore, user, at: Time.current + 5.hours).call
      expect(second.completion.payout_skipped).to be(true)
      # Different chore-day → cooldown elapsed.
      expect(chore.cooldown_elapsed?(user, last_completion: second.completion,
                                     now: Time.current + 26.hours)).to be(true)
    end
  end

  # The unified page is now JSON-bootstrap-driven (no server-rendered
  # cards). Ordering / visibility are asserted against the bootstrap
  # JSON inlined in the page, which is the same payload the client
  # `ChoreStore` reads on load.
  def bootstrap_json
    md = response.body.match(%r{<script type="application/json" id="chores-bootstrap">\s*(.+?)\s*</script>}m)
    raise "no bootstrap script in response" unless md

    JSON.parse(md[1])
  end

  it "PATCH /chores/order saves per-user ordering and bootstrap JSON honors it" do
    a = create(:chore, created_by_user: user, name: "Alpha")
    b = create(:chore, created_by_user: user, name: "Bravo")
    c = create(:chore, created_by_user: user, name: "Charlie")

    patch "/chores/order",
      params: { ids: [c.id, a.id, b.id] }.to_json,
      headers: { "CONTENT_TYPE" => "application/json", "Accept" => "application/json" }
    expect(response).to have_http_status(:ok)

    get chores_path
    names = bootstrap_json["chores"].map { |c| c["name"] }
    expect(names.index("Charlie")).to be < names.index("Alpha")
    expect(names.index("Alpha")).to be < names.index("Bravo")
  end

  it "New chores appear at the end of the per-user ordering" do
    a = create(:chore, created_by_user: user, name: "Alpha")
    b = create(:chore, created_by_user: user, name: "Bravo")
    patch "/chores/order",
      params: { ids: [b.id, a.id] }.to_json,
      headers: { "CONTENT_TYPE" => "application/json", "Accept" => "application/json" }
    create(:chore, created_by_user: user, name: "Zulu")
    get chores_path
    names = bootstrap_json["chores"].map { |c| c["name"] }
    expect(names.index("Bravo")).to be < names.index("Alpha")
    expect(names.index("Alpha")).to be < names.index("Zulu")
  end

  it "Today view keeps an item visible after completion even when the enum would hide it" do
    # `:when_available` would hide after a payout (cooldown not elapsed),
    # but the frozen-layout rule wins: any chore with completions today
    # stays on the list. Verified through the bootstrap JSON's
    # `today_visible` flag.
    chore = create(:chore, created_by_user: user,
      reward_pebbles: 3, threshold_seconds: 6 * 3600,
      show_on_daily_view: :when_available,
      recurrence: { freq: :never })
    ChoreCompleter.new(chore, user).call
    get chores_today_path
    expect(response).to have_http_status(:ok)
    payload = bootstrap_json["chores"].find { |c| c["id"] == chore.id }
    expect(payload).to be_present
    expect(payload["today_visible"]).to be(true)
  end
end
