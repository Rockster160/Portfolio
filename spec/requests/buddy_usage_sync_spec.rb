require "rails_helper"

RSpec.describe "POST /api/v1/buddy_usages", type: :request do
  let(:user) { User.me }
  let(:api_key) { user.api_keys.create!(name: "laptop") }
  let(:headers) { { "Authorization" => "Bearer #{api_key.key}" } }

  def row(**overrides)
    {
      origin_uid:          "laptop:development:41:2026-08-20T18:04:00.000Z",
      env:                 "development",
      kind:                "eval",
      model:               "gpt-5.4-mini",
      input_tokens:        1_000,
      cached_input_tokens: 800,
      output_tokens:       100,
      reasoning_tokens:    20,
      cost_micros:         1_234,
      username:            user.username,
      recorded_at:         "2026-08-20T18:04:00.000Z",
    }.merge(overrides)
  end

  def post_rows(rows, as_headers: headers)
    post "/api/v1/buddy_usages", params: { usages: rows }, headers: as_headers, as: :json
  end

  it "records spend that happened somewhere else" do
    expect { post_rows([row]) }.to change(BuddyUsage, :count).by(1)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["data"]).to include("received" => 1, "created" => 1)

    expect(BuddyUsage.last).to have_attributes(
      user_id:     user.id,
      env:         "development",
      kind:        "eval",
      cost_micros: 1_234,
      origin_uid:  "laptop:development:41:2026-08-20T18:04:00.000Z",
    )
  end

  # A month of evals arriving at once must not land on today.
  it "keeps the moment the money was spent" do
    post_rows([row])

    expect(BuddyUsage.last.created_at).to eq(Time.zone.parse("2026-08-20T18:04:00.000Z"))
  end

  # A batch that times out after the insert looks exactly like one that never
  # landed, so the spool re-sends the whole file.
  it "takes the same row twice without recording it twice" do
    post_rows([row])

    expect { post_rows([row]) }.not_to change(BuddyUsage, :count)
    expect(response.parsed_body["data"]).to include("duplicate" => 1, "created" => 0)
  end

  it "skips a row it cannot record faithfully rather than guessing" do
    rows = [
      row(origin_uid: "a", env: "staging"),
      row(origin_uid: "b", kind: "daydream"),
      row(origin_uid: "c", recorded_at: "whenever"),
      row(origin_uid: nil),
    ]

    expect { post_rows(rows) }.not_to change(BuddyUsage, :count)
    expect(response.parsed_body["data"]).to include("skipped" => 4)
  end

  it "refuses a batch bigger than it will take" do
    stub_const("Api::V1::BuddyUsagesController::MAX_BATCH", 2)

    post_rows([row(origin_uid: "a"), row(origin_uid: "b"), row(origin_uid: "c")])

    expect(response).to have_http_status(:unprocessable_entity)
    expect(BuddyUsage.count).to eq(0)
  end

  it "turns away a request with no key" do
    post_rows([row], as_headers: {})

    expect(response).to have_http_status(:unauthorized)
    expect(BuddyUsage.count).to eq(0)
  end

  describe "who it gets filed against" do
    let(:other) {
      User.create!(
        username:              "spoolmate-#{SecureRandom.hex(4)}",
        password:              "abcd1234!",
        password_confirmation: "abcd1234!",
      )
    }

    it "files it against the person named on the row" do
      post_rows([row(username: other.username)])

      expect(BuddyUsage.last.user_id).to eq(other.id)
    end

    it "falls back to the key's owner when the name means nothing here" do
      post_rows([row(username: "nobody-by-that-name")])

      expect(BuddyUsage.last.user_id).to eq(user.id)
    end

    it "does not let one person file spend against another" do
      key = other.api_keys.create!(name: "theirs")

      post_rows([row(username: user.username)], as_headers: { "Authorization" => "Bearer #{key.key}" })

      expect(BuddyUsage.last.user_id).to eq(other.id)
    end
  end
end
