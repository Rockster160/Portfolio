require "rails_helper"

RSpec.describe "Automation health page", type: :request do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }

  def failing_task(owner, name)
    create(:task, user: owner, name: name).tap { |task|
      create(:execution, task: task, status: :failed, started_at: 1.hour.ago)
    }
  end

  before {
    post login_path, params: { user: { username: user.username, password: "password123" } }
  }

  it "renders this person's problems and none of another person's" do
    failing_task(user, "Garage Closer")
    failing_task(other_user, "Someone Elses Task")

    get jil_health_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Garage Closer")
    expect(response.body).not_to include("Someone Elses Task")
  end
end
