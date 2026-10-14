require "rails_helper"

# Building a routine from the panel.
#
# The steps are tool calls with validated arguments, and the old objection was
# that a text box is a bad place to write one. The box was the problem: the
# fields come from the tool registry, so only arguments that exist can be
# offered, and the server runs the same `Buddy::Routines.sanitize` a routine
# saved in conversation goes through - including each tool's own `confirm`, so a
# step naming a chore nobody has is refused rather than saved broken.
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
    it "offers the tools a routine can replay" do
      get "/buddy/routines/tools"

      names = json["tools"].pluck("name")
      expect(names).to include("complete_chore")
      expect(response).to have_http_status(:ok)
    end

    # `routinable: false` is the declaration that a tool's whole value is one
    # particular moment - filing a gap somebody hit, answering the question in
    # front of them. Replaying one is never what anybody wanted.
    it "leaves out the ones whose value is a single moment" do
      get "/buddy/routines/tools"

      expect(json["tools"].pluck("name")).not_to include("request_feature")
    end

    # An :object arg is a shape rather than a value, and a field asking for one
    # would be a step that looks filled in and fails.
    it "leaves out a tool that needs something a field can't hold" do
      get "/buddy/routines/tools"

      expect(json["tools"].pluck("name")).not_to include("answer_prompt")
    end

    it "carries each argument's type and whether it's needed" do
      get "/buddy/routines/tools"

      arg = json["tools"].find { |t| t["name"] == "complete_chore" }["args"].find { |a| a["key"] == "chore" }
      expect(arg).to include("type" => "string", "required" => true)
      expect(arg["description"]).to be_present
    end

    # Two arguments because the model picks whichever matches how it was said.
    # Offered raw they were two empty boxes under a hint explaining to use one
    # and not the other.
    describe "a length" do
      before { get "/buddy/routines/tools" }

      let(:timer) { json["tools"].find { |t| t["name"] == "set_timer" } }

      it "is one field rather than a seconds box and a minutes box" do
        keys = timer["args"].pluck("key")

        expect(keys).to include("seconds")
        expect(keys).not_to include("minutes")
      end

      it "says which unit it converts back into" do
        seconds = timer["args"].find { |a| a["key"] == "seconds" }

        expect(seconds).to include("type" => "duration", "unit" => "seconds")
      end

      it "drops the description about which of the two to use" do
        seconds = timer["args"].find { |a| a["key"] == "seconds" }

        expect(seconds["description"]).not_to match(/OR minutes/i)
      end

      # Minutes of break between blocks is a length too, whatever it is called.
      it "takes a minutes-only argument the same way" do
        brk = timer["args"].find { |a| a["key"] == "break_minutes" }

        expect(brk).to include("type" => "duration", "unit" => "minutes")
      end
    end

    # set_timer takes ten arguments, six of them about a repeating work/break
    # rhythm with a stop condition. Asked all at once a form reads as ten
    # decisions rather than one.
    describe "how much it asks at once" do
      before { get "/buddy/routines/tools" }

      it "keeps a length and anything required on screen" do
        timer = json["tools"].find { |t| t["name"] == "set_timer" }
        shown = timer["args"].reject { |a| a["advanced"] }.pluck("key")

        expect(shown).to eq(["seconds"])
      end

      it "folds the rest away rather than dropping them" do
        timer = json["tools"].find { |t| t["name"] == "set_timer" }
        folded = timer["args"].select { |a| a["advanced"] }.pluck("key")

        expect(folded).to include("label", "repeat", "stop_when", "break_minutes")
      end

      it "keeps a required argument on screen beside the optional ones folded away" do
        chore = json["tools"].find { |t| t["name"] == "complete_chore" }
        shown = chore["args"].reject { |a| a["advanced"] }.pluck("key")

        expect(shown).to eq(["chore"])
      end

      # Folding everything would leave a form with nothing on it.
      it "shows the lot when nothing stands out" do
        loose = json["tools"].find { |t|
          t["args"].any? && t["args"].none? { |a| a["required"] || %w[seconds minutes duration].include?(a["key"]) }
        }

        expect(loose).to be_present
        expect(loose["args"].select { |a| a["advanced"] }).to be_empty
      end
    end

    # The descriptions are written for the model and run to paragraphs. One line
    # is what fits beside a name in a list.
    it "says what a tool is for in one line" do
      get "/buddy/routines/tools"

      blurbs = json["tools"].filter_map { |t| t["description"] }
      expect(blurbs).to be_present
      expect(blurbs.map(&:length).max).to be <= 140
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
      expect(BuddyRoutine.find(json["id"]).steps.pluck("tool_name"))
        .to eq(%w[set_timer complete_chore])
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

    it "refuses a tool that can't be replayed" do
      post "/buddy/routines", params: {
        name:  "Nope",
        steps: [{ tool_name: "request_feature", payload: { title: "a", body: "b" } }],
      }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json["errors"].join).to match(/can't be saved in a routine/i)
    end

    it "wants a name" do
      post "/buddy/routines", params: {
        steps: [{ tool_name: "complete_chore", payload: { chore: "Load Dishes" } }],
      }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json["errors"].join).to match(/needs a name/i)
    end

    it "refuses a second one by the same name" do
      user.buddy_routines.create!(
        name: "Kitchen reset", steps: [BuddyRoutine.step("complete_chore", { chore: "Load Dishes" })],
      )

      post "/buddy/routines", params: {
        name:  "kitchen RESET",
        steps: [{ tool_name: "complete_chore", payload: { chore: "Load Dishes" } }],
      }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json["errors"].join).to match(/already have one called/i)
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
      expect(routine.reload.steps.map { |s| s.dig("payload", "chore") })
        .to eq(["A Chore Nobody Has", "Load Dishes"])
    end

    it "still refuses to empty one out" do
      patch "/buddy/routines/#{routine.id}/steps", params: { steps: [] }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(routine.reload.steps.length).to eq(1)
    end
  end
end
