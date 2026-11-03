require "rails_helper"

# Building a routine from the panel. The fields come from the tool registry,
# and the server runs the same `Buddy::Routines.sanitize` a routine saved in
# conversation goes through - including each tool's own `confirm`, so a step
# naming a chore nobody has is refused rather than saved broken.
RSpec.describe "Building a Buddy routine", type: :request do
  let(:user) { User.me }
  let!(:chore) { create(:chore, created_by_user: user, name: "Load Dishes", recurrence: { "freq" => "daily" }) }

  def sign_in
    user.update!(password: "password123", password_confirmation: "password123")
    host! "byte.example.com"
    post login_path, params: { user: { username: user.username, password: "password123" } }
  end

  before { sign_in }

  def json = response.parsed_body

  describe "GET /buddy/routines/tools" do
    before { get "/buddy/routines/tools" }

    def tool(name) = json["tools"].find { |t| t["name"] == name }

    # `routinable: false` declares a tool whose whole value is one moment, and an
    # :object arg is a shape a field can't hold; neither is offered.
    it "offers the tools a routine can replay, with each argument's type and need", :aggregate_failures do
      expect(response).to have_http_status(:ok)
      names = json["tools"].pluck("name")
      expect(names).to include("complete_chore")
      expect(names).not_to include("request_feature", "answer_prompt")

      arg = tool("complete_chore")["args"].find { |a| a["key"] == "chore" }
      expect(arg).to include("type" => "string", "required" => true)
      expect(arg["description"]).to be_present

      # The descriptions are written for the model; one line is what fits in a list.
      blurbs = json["tools"].filter_map { |t| t["description"] }
      expect(blurbs.map(&:length).max).to be <= 140
    end

    # Seconds-or-minutes is offered as one duration field, and the optional
    # arguments fold away so a form reads as one decision rather than ten.
    it "turns a length into one duration field and folds the optional arguments", :aggregate_failures do
      args = tool("set_timer")["args"]
      expect(args.pluck("key")).to include("seconds")
      expect(args.pluck("key")).not_to include("minutes")
      expect(args.find { |a| a["key"] == "seconds" }).to include("type" => "duration", "unit" => "seconds")
      expect(args.find { |a| a["key"] == "break_minutes" }).to include("type" => "duration", "unit" => "minutes")

      expect(args.reject { |a| a["advanced"] }.pluck("key")).to eq(["seconds"])
      expect(args.select { |a| a["advanced"] }.pluck("key")).to include("label", "repeat", "stop_when", "break_minutes")
      expect(tool("complete_chore")["args"].reject { |a| a["advanced"] }.pluck("key")).to eq(["chore"])

      # Folding everything would leave a form with nothing on it.
      loose = json["tools"].find { |t|
        t["args"].any? && t["args"].none? { |a| a["required"] || %w[seconds minutes duration].include?(a["key"]) }
      }
      expect(loose["args"].select { |a| a["advanced"] }).to be_empty
    end
  end

  describe "POST /buddy/routines with steps" do
    it "saves one built out of them" do
      post "/buddy/routines", params: {
        name:  "Kitchen reset",
        steps: [{ tool_name: "complete_chore", payload: { chore: "Load Dishes" } }],
      }, as: :json

      expect(response).to have_http_status(:created)
      expect(BuddyRoutine.find(json["id"]).steps.first["tool_name"]).to eq("complete_chore")
    end

    it "takes several steps in the order they were added" do
      post "/buddy/routines", params: {
        name:  "Wind down",
        steps: [
          { tool_name: "set_timer", payload: { seconds: 60, then_continue: true } },
          { tool_name: "complete_chore", payload: { chore: "Load Dishes" } },
        ],
      }, as: :json

      expect(response).to have_http_status(:created)
      expect(BuddyRoutine.find(json["id"]).steps.pluck("tool_name")).to eq(%w[set_timer complete_chore])
    end

    # The whole reason this goes through sanitize rather than straight into the
    # column: the tool's own `confirm` is what knows whether the name resolves,
    # and it says so in a sentence worth showing.
    it "refuses a step naming something that isn't there, in the tool's words" do
      post "/buddy/routines", params: {
        name:  "Nope",
        steps: [{ tool_name: "complete_chore", payload: { chore: "Polish the Zeppelin" } }],
      }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json["errors"].join).to match(/zeppelin/i)
      expect(BuddyRoutine.where(name: "Nope")).to be_empty
    end

    it "refuses a tool that can't be replayed, a missing name, and a name already taken" do
      user.buddy_routines.create!(
        name: "Kitchen reset", steps: [BuddyRoutine.step("complete_chore", { chore: "Load Dishes" })],
      )
      chore_step = { tool_name: "complete_chore", payload: { chore: "Load Dishes" } }

      [
        { name: "Nope", steps: [{ tool_name: "request_feature", payload: { title: "a", body: "b" } }] },
        { steps: [chore_step] },
        { name: "kitchen RESET", steps: [chore_step] },
      ].each do |params|
        expect { post "/buddy/routines", params: params, as: :json }.not_to change(BuddyRoutine, :count)
        expect(response).to have_http_status(:unprocessable_entity), params.to_s
        expect(json["errors"]).to be_present
      end
    end

    # Wrapping a Jil automation is the same endpoint and still works off a task
    # id alone, since there is nothing to fill in.
    it "still wraps a Jil automation as a one-step button" do
      task = user.tasks.create!(name: "Fan High", listener: "fan-high", buddy_enabled: true, code: "")

      post "/buddy/routines", params: { task_id: task.id }, as: :json

      expect(response).to have_http_status(:created)
      expect(BuddyRoutine.find(json["id"]).steps.first["tool_name"]).to eq("trigger_jil_task")
    end
  end

  describe "PATCH /buddy/routines/:id/steps" do
    let!(:routine) {
      user.buddy_routines.create!(
        name:  "Kitchen reset",
        steps: [BuddyRoutine.step("complete_chore", { chore: "Load Dishes" })],
      )
    }

    it "appends a new step beside the ones already saved" do
      patch "/buddy/routines/#{routine.id}/steps", params: {
        steps: [
          { index: 0, count: 1 },
          { tool_name: "set_timer", payload: { seconds: 60, then_continue: true } },
        ],
      }, as: :json

      expect(response).to have_http_status(:ok)
      expect(routine.reload.steps.pluck("tool_name")).to eq(%w[complete_chore set_timer])
    end

    it "puts a new step wherever it was sent" do
      patch "/buddy/routines/#{routine.id}/steps", params: {
        steps: [
          { tool_name: "set_timer", payload: { seconds: 60, then_continue: true } },
          { index: 0, count: 1 },
        ],
      }, as: :json

      expect(routine.reload.steps.pluck("tool_name")).to eq(%w[set_timer complete_chore])
    end

    it "refuses a new step that doesn't resolve and leaves the routine alone" do
      patch "/buddy/routines/#{routine.id}/steps", params: {
        steps: [
          { index: 0, count: 1 },
          { tool_name: "complete_chore", payload: { chore: "Polish the Zeppelin" } },
        ],
      }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(routine.reload.steps.length).to eq(1)
    end

    # A kept step rides through as it was stored and is never re-checked, so a
    # routine that has gone stale can still be reordered and pruned.
    it "lets a stale routine be rearranged" do
      stale = [
        BuddyRoutine.step("complete_chore", { chore: "Load Dishes" }),
        BuddyRoutine.step("complete_chore", { chore: "A Chore Nobody Has" }),
      ]
      # Past the model, deliberately: the point is a routine that could not be
      # saved as it stands and still has to be rearrangeable.
      routine.update_column(:steps, stale) # rubocop:disable Rails/SkipsModelValidations

      patch "/buddy/routines/#{routine.id}/steps", params: {
        steps: [{ index: 1, count: 1 }, { index: 0, count: 1 }],
      }, as: :json

      expect(response).to have_http_status(:ok)
      expect(routine.reload.steps.map { |s| s.dig("payload", "chore") }).to eq(["A Chore Nobody Has", "Load Dishes"])
    end

    it "still refuses to empty one out" do
      patch "/buddy/routines/#{routine.id}/steps", params: { steps: [] }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(routine.reload.steps.length).to eq(1)
    end
  end
end
