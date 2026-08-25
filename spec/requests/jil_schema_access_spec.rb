require "rails_helper"

# The editor page carries the whole Jil vocabulary inline as `window.load_schema`.
# Gating it is only worth anything if the gate survives the round trip to the
# page — and the read-only shared case is where a naive filter breaks the editor
# outright, because jil/schema.js dereferences `types[name]` without a guard.
RSpec.describe "Jil schema access", type: :request do
  let(:owner) { User.me }
  let(:other) { create(:user) }

  def sign_in_as(target)
    target.update!(password: "password123", password_confirmation: "password123")
    post login_path, params: { user: { username: target.username, password: "password123" } }
  end

  def owner_task(code)
    Task.create!(user: owner, name: "Drive", listener: "tell:drive", code: code, enabled: true)
  end

  it "offers the owner-only classes to the owner's editor" do
    sign_in_as(owner)
    get jil_task_path(owner_task("// noop"))

    expect(response.body).to include("[Tesla]")
    expect(response.body).to include("[Mac]")
  end

  it "withholds them from someone else's editor" do
    sign_in_as(other)
    get new_jil_task_path

    expect(response.body).not_to include("[Tesla]")
    expect(response.body).not_to include("[Mac]")
  end

  # She is already looking at the code that names the class; keeping the
  # definition is what lets the page draw it.
  it "keeps a class the shared task on screen actually uses" do
    task = owner_task("nav = Tesla.navigate(dest)::Boolean")
    task.shared_tasks.create!(user: other)
    sign_in_as(other)

    get jil_task_path(task)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("[Tesla]")
  end

  it "still withholds the classes that shared task does not use" do
    task = owner_task("nav = Tesla.navigate(dest)::Boolean")
    task.shared_tasks.create!(user: other)
    sign_in_as(other)

    get jil_task_path(task)

    expect(response.body).not_to include("[Mac]")
  end
end
