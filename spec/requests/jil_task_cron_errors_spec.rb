require "rails_helper"

# The editor's save button only shows a message when the response is non-2xx and
# carries `errors`. Rendering 200 with the unsaved record made a rejected save
# look accepted, which is the whole reason a bad cron went unnoticed.
RSpec.describe "Jil task cron errors", type: :request do
  let(:user) { create(:user) }

  def sign_in_as(target)
    post login_path, params: { user: { username: target.username, password: "password123" } }
  end

  before do
    sign_in_as(user)
    user.anchors.create!(key: "sun:sunset").set_occurrence(1.hour.from_now, identifier: "today")
  end

  def task_attrs(cron)
    { name: "Porch Lights", listener: "tell:porch", code: "// noop", cron: cron }
  end

  describe "create" do
    it "reports an unreadable cron instead of pretending to save" do
      post jil_tasks_path, params: { task: task_attrs("sun:sunset-5") }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["errors"].join).to include("offset")
      expect(user.tasks.count).to eq(0)
    end

    # A placeholder written before its feeder saves fine and says so.
    it "saves against an anchor that doesn't exist yet, with a warning" do
      post jil_tasks_path, params: { task: task_attrs("school:bell-10m") }

      expect(response).to have_http_status(:ok)
      expect(user.tasks.count).to eq(1)
      expect(response.parsed_body["warnings"].join).to include("school:bell", "doesn't exist yet")
    end

    it "saves a good anchor and reports the resolved run time" do
      post jil_tasks_path, params: { task: task_attrs("sun:sunset-5m") }

      expect(response).to have_http_status(:ok)
      expect(user.tasks.sole.next_trigger_at).to be_present
      expect(response.parsed_body["warnings"]).to be_empty
    end
  end

  describe "update" do
    let!(:task) { user.tasks.create!(task_attrs("0 6 * * *")) }

    it "reports an unreadable cron and leaves the stored one alone" do
      patch jil_task_path(task), params: { task: { cron: "sun:sunset-5" } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["errors"].join).to include("offset")
      expect(task.reload.cron).to eq("0 6 * * *")
    end

    it "accepts a switch to an anchor" do
      patch jil_task_path(task), params: { task: { cron: "sun:sunset-5m" } }

      expect(response).to have_http_status(:ok)
      expect(task.reload.cron).to eq("sun:sunset-5m")
      expect(task.next_trigger_at).to be_present
    end
  end
end
