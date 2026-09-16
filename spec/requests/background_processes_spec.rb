require "rails_helper"

# The endpoint the scripts report through, and the same one the page hydrates
# and clears with. Every route has to survive being called twice, because the
# callers are scripts that cannot tell a timeout from a success.
RSpec.describe "Background processes", type: :request do
  let(:user) { create(:user) }

  def json = response.parsed_body["data"]

  def sign_in!
    post login_path, params: { user: { username: user.username, password: "password123" } }
  end

  describe "POST /api/v1/background_processes" do
    before { sign_in! }

    it "starts one" do
      post "/api/v1/background_processes",
        params: { key: "jobhunt:line", name: "Preparing", current: 1, total: 13 }

      expect(response).to have_http_status(:ok)
      expect(json.dig("process", "name")).to eq("Preparing")
      expect(json.dig("process", "current")).to eq(1)
      expect(BackgroundProcess.live_for(user).count).to eq(1)
    end

    it "steps the one already there instead of stacking a second" do
      post "/api/v1/background_processes", params: { key: "jobhunt:line", name: "Preparing", current: 1 }
      post "/api/v1/background_processes", params: { key: "jobhunt:line", current: 2 }

      expect(BackgroundProcess.live_for(user).count).to eq(1)
      expect(json.dig("process", "current")).to eq(2)
      expect(json.dig("process", "name")).to eq("Preparing")
    end

    it "takes links as a list of objects" do
      post "/api/v1/background_processes",
        params:  {
          key:   "jobhunt:line",
          name:  "Preparing",
          links: [
            { label: "Posting", url: "https://boards.greenhouse.io/x/jobs/1" },
            { label: "Line", url: "http://localhost:8790/line" },
          ],
        }.to_json,
        headers: { "CONTENT_TYPE" => "application/json" }

      expect(json.dig("process", "links").pluck("label")).to eq(%w[Posting Line])
    end

    # A form-encoded caller cannot send a nested array at all, so it sends the
    # JSON as a string and this is where that is read.
    it "takes links as a json string" do
      post "/api/v1/background_processes",
        params: {
          key:   "jobhunt:line",
          name:  "Preparing",
          links: [{ label: "Posting", url: "https://example.com/job" }].to_json,
        }

      expect(json.dig("process", "links").pluck("label")).to eq(["Posting"])
    end

    # The report is still good. Losing the progress it was carrying over a
    # malformed link would be the worse trade.
    it "keeps the report when the links are unreadable" do
      post "/api/v1/background_processes",
        params: { key: "jobhunt:line", name: "Preparing", current: 2, links: "not json" }

      expect(response).to have_http_status(:ok)
      expect(json.dig("process", "current")).to eq(2)
      expect(json.dig("process", "links")).to eq([])
    end

    it "refuses one with no key" do
      post "/api/v1/background_processes", params: { name: "Nameless" }

      expect(response).to have_http_status(:unprocessable_entity)
    end

    # A count arriving as a string from a form-encoded caller is still a count.
    it "reads the numbers whichever way they were sent" do
      post "/api/v1/background_processes",
        params:  { key: "mail:triage", name: "Reading", current: "3", total: "7" }.to_json,
        headers: { "CONTENT_TYPE" => "application/json" }

      expect(json.dig("process", "current")).to eq(3)
      expect(json.dig("process", "total")).to eq(7)
    end
  end

  describe "PATCH /api/v1/background_processes/:key" do
    before { sign_in! }

    it "puts back one that was cleared mid-run" do
      post "/api/v1/background_processes", params: { key: "jobhunt:line", name: "Preparing", current: 1 }
      delete "/api/v1/background_processes/jobhunt:line"
      patch "/api/v1/background_processes/jobhunt:line", params: { name: "Preparing", current: 5 }

      expect(response).to have_http_status(:ok)
      expect(BackgroundProcess.live_for(user).count).to eq(1)
      expect(json.dig("process", "current")).to eq(5)
    end

    it "takes a state" do
      patch "/api/v1/background_processes/jobhunt:line",
        params: { name: "Filling in", state: "waiting", detail: "8 questions" }

      expect(json.dig("process", "state")).to eq("waiting")
      expect(json.dig("process", "detail")).to eq("8 questions")
    end
  end

  describe "DELETE /api/v1/background_processes/:key" do
    before { sign_in! }

    it "clears it and says so" do
      post "/api/v1/background_processes", params: { key: "jobhunt:line", name: "Preparing" }
      delete "/api/v1/background_processes/jobhunt:line"

      expect(json["cleared"]).to be(true)
      expect(BackgroundProcess.live_for(user)).to be_empty
    end

    # The browser encodes the colon in "jobhunt:line" as %3A, so the path the
    # strip actually sends is not the one written here by hand.
    it "takes the key url-encoded" do
      post "/api/v1/background_processes", params: { key: "jobhunt:line", name: "Preparing" }
      delete "/api/v1/background_processes/jobhunt%3Aline"

      expect(json["cleared"]).to be(true)
      expect(BackgroundProcess.live_for(user)).to be_empty
    end

    it "says ok for a key with nothing behind it" do
      delete "/api/v1/background_processes/never:ran"

      expect(response).to have_http_status(:ok)
      expect(json["cleared"]).to be(false)
    end
  end

  describe "GET /api/v1/background_processes" do
    before { sign_in! }

    it "lists what is running, and only this person's" do
      post "/api/v1/background_processes", params: { key: "jobhunt:line", name: "Preparing" }
      BackgroundProcess.report!(user: create(:user), key: "jobhunt:line", name: "Somebody else's")

      get "/api/v1/background_processes"

      expect(json["processes"].pluck("name")).to eq(["Preparing"])
    end
  end

  describe "a local script with the shared secret" do
    before do
      allow(ByteLocal).to receive(:valid_secret?).and_return(false)
      allow(ByteLocal).to receive(:valid_secret?).with("shh").and_return(true)
    end

    it "reports without a session" do
      post "/api/v1/background_processes",
        params:  { key: "mail:watcher", name: "Reading mail", user_id: user.id },
        headers: { "X-Byte-Secret" => "shh" }

      expect(response).to have_http_status(:ok)
      expect(BackgroundProcess.live_for(user).count).to eq(1)
    end

    it "is turned away with the wrong secret" do
      post "/api/v1/background_processes",
        params:  { key: "mail:watcher", name: "Reading mail", user_id: user.id },
        headers: { "X-Byte-Secret" => "nope" }

      expect(response).to have_http_status(:unauthorized)
      expect(BackgroundProcess.count).to eq(0)
    end
  end
end
