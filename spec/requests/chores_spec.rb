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
    create(:chore_goal, user: user, name: "Lego Set", cost_pebbles: 500)
    get chores_balance_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Lego Set")
  end

  it "POST /chores/items creates a chore" do
    expect {
      post "/chores/items",
        params: { chore: { name: "Vacuum", reward_pebbles: 5, icon: "🧹" } }.to_json,
        headers: { "CONTENT_TYPE" => "application/json", "Accept" => "application/json" }
    }.to change(Chore, :count).by(1)
    expect(response).to have_http_status(:created)
  end

  it "POST /chores/items/:id/completion creates a completion + updates balance" do
    chore = create(:chore, created_by_user: user, name: "Walk", reward_pebbles: 5)
    expect {
      post "/chores/items/#{chore.id}/completion",
        headers: { "Accept" => "application/json" }
    }.to change(ChoreCompletion, :count).by(1)
    body = JSON.parse(response.body)
    expect(body["balance"]).to eq(5)
    expect(body["completions_today"]).to eq(1)
  end

  it "DELETE completion removes the most recent and updates balance" do
    chore = create(:chore, created_by_user: user, name: "Walk", reward_pebbles: 5)
    ChoreCompleter.new(chore, user).call
    expect(user.chore_balance).to eq(5)

    delete "/chores/items/#{chore.id}/completion", headers: { "Accept" => "application/json" }
    expect(response).to have_http_status(:ok)
    expect(user.reload.chore_balance).to eq(0)
  end

  it "GET /chores/history lists completions" do
    chore = create(:chore, created_by_user: user, name: "Vacuum", reward_pebbles: 5)
    create(:chore_completion, chore: chore, user: user, paid_pebbles: 5)
    get chores_history_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Vacuum")
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

  it "GET /chores/history filters with .query (note + chore name + time)" do
    cat = create(:chore, created_by_user: user, name: "Brush kitty")
    dog = create(:chore, created_by_user: user, name: "Feed dog")
    create(:chore_completion, chore: cat, user: user, note: "morning",
      completed_at: 2.days.ago, day_key: 2.days.ago.to_date)
    create(:chore_completion, chore: dog, user: user, note: "evening",
      completed_at: 1.day.ago, day_key: 1.day.ago.to_date)

    # Free keyword falls through to the chore name.
    get chores_history_path(q: "kitty")
    expect(response.body).to include("Brush kitty")
    expect(response.body).not_to include("Feed dog")

    # notes alias works.
    get chores_history_path(q: "notes:evening")
    expect(response.body).to include("Feed dog")
    expect(response.body).not_to include("Brush kitty")
  end

  it "GET /chores/history reports total count + page metadata" do
    chore = create(:chore, created_by_user: user, name: "Walk")
    60.times { |i|
      create(:chore_completion, chore: chore, user: user,
        completed_at: i.hours.ago, day_key: ChoreDay.current(user))
    }
    get chores_history_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("of <strong>60</strong>")
    expect(response.body).to include("Page <strong>1</strong>")
    expect(response.body).to include("of <strong>2</strong>")
  end

  it "GET /chores/history mixes completions + withdrawals newest first" do
    chore = create(:chore, created_by_user: user, name: "Mix")
    create(:chore_completion, chore: chore, user: user, paid_pebbles: 3,
      completed_at: 2.hours.ago)
    create(:chore_withdrawal, user: user, amount_pebbles: 2, note: "candy")
    get chores_history_path
    expect(response).to have_http_status(:ok)
    body = response.body
    # Withdrawal (newer) appears before completion (2h older)
    expect(body.index("candy")).to be < body.index("Mix")
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

  it "GET /chores/items/:id/state returns per-chore live data + server_ts" do
    chore = create(:chore, created_by_user: user, reward_pebbles: 4)
    create(:chore_completion, chore: chore, user: user, paid_pebbles: 4)
    get "/chores/items/#{chore.id}/state", headers: { "Accept" => "application/json" }
    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body["chore_id"]).to eq(chore.id)
    expect(body["completions_today"]).to eq(1)
    expect(body["balance"]).to eq(4)
    expect(body["server_ts"]).to be_present
    expect(body["last_completed_at"]).to be_present
    # New dual-html shape used by the unified-page diff applier.
    expect(body["html_grid"]).to be_present
    expect(body["html_today"]).to be_present
    expect(body["today_visible"]).to be(true).or be(false)
  end

  it "GET /chores/sync returns diff payload for both views" do
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
    expect(keeper_payload["html_grid"]).to include("Vacuum")
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
    chore = create(:chore, created_by_user: user, reward_pebbles: 5, threshold_seconds: -1)
    first  = ChoreCompleter.new(chore, user, at: Time.current).call
    expect(first.completion.payout_skipped).to be(false)
    second = ChoreCompleter.new(chore, user, at: Time.current + 5.hours).call
    expect(second.completion.payout_skipped).to be(true)
    # Different chore-day → cooldown elapsed.
    expect(chore.cooldown_elapsed?(user, last_completion: second.completion,
                                   now: Time.current + 26.hours)).to be(true)
  end

  it "PATCH /chores/order saves per-user ordering and Grid honors it" do
    a = create(:chore, created_by_user: user, name: "Alpha")
    b = create(:chore, created_by_user: user, name: "Bravo")
    c = create(:chore, created_by_user: user, name: "Charlie")

    patch "/chores/order",
      params: { ids: [c.id, a.id, b.id] }.to_json,
      headers: { "CONTENT_TYPE" => "application/json", "Accept" => "application/json" }
    expect(response).to have_http_status(:ok)

    get chores_path
    pos = ->(name) { response.body.index(%(data-chore-name="#{name}")) }
    expect(pos["Charlie"]).to be < pos["Alpha"]
    expect(pos["Alpha"]).to be < pos["Bravo"]
  end

  it "New chores appear at the end of the per-user ordering" do
    a = create(:chore, created_by_user: user, name: "Alpha")
    b = create(:chore, created_by_user: user, name: "Bravo")
    patch "/chores/order",
      params: { ids: [b.id, a.id] }.to_json,
      headers: { "CONTENT_TYPE" => "application/json", "Accept" => "application/json" }
    later = create(:chore, created_by_user: user, name: "Zulu")
    get chores_path
    pos = ->(name) { response.body.index(%(data-chore-name="#{name}")) }
    expect(pos["Bravo"]).to be < pos["Alpha"]
    expect(pos["Alpha"]).to be < pos["Zulu"]
  end

  it "Today view keeps an item visible after completion even when the enum would hide it" do
    # `:when_available` would hide after a payout (cooldown not elapsed),
    # but the frozen-layout rule wins: any chore with completions today
    # stays on the list.
    chore = create(:chore, created_by_user: user,
      reward_pebbles: 3, threshold_seconds: 6 * 3600,
      show_on_daily_view: :when_available,
      recurrence: { freq: :never })
    ChoreCompleter.new(chore, user).call
    get chores_today_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include(%(data-chore-id="#{chore.id}"))
  end
end
