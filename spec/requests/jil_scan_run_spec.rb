require "rails_helper"

RSpec.describe "Task short links and run-on-scan", type: :request do
  let(:user) { User.me }
  let(:password) { "password123" }
  let(:task) {
    user.tasks.create!(
      name:     "Porch Lights",
      listener: "porch_lights",
      code:     <<~JIL.strip,
        ok = Global.print("ran")::String
      JIL
    )
  }

  before do
    allow(::Jil::Executor).to receive(:async_call)
    user.update!(password: password, password_confirmation: password)
    post "/login", params: { user: { username: user.username, password: password } }
    # After signing in: Rack::Attack counts logins in whatever cache it sees first
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
  end

  it "gives every new task a letters-only short key" do
    expect(task.short_key).to match(/\A[A-HJ-NP-Z]{4}\z/)
  end

  it "opens the trigger page by short key, in any case, and by the old numeric id" do
    get "/t/#{task.short_key.downcase}"
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include(task.scan_run_url)

    get "/jil/tasks/#{task.id}"
    expect(response.body).to include(%(data-url="https://#{task.short_url}"), %(data-url="https://#{task.scan_run_url}"))

    get "/t/#{task.id}"
    expect(response).to have_http_status(:ok)
  end

  it "still sends a long share token to the timer share" do
    get "/t/#{SecureRandom.urlsafe_base64(16)}"
    expect(response).to have_http_status(:gone)
  end

  it "runs nothing on the GET, and once per pass on the POST" do
    get "/r/#{task.short_key}"
    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to include("no-store")
    expect(::Jil::Executor).not_to have_received(:async_call)

    pass = response.body[/pass=("[^"]+")/, 1].then { |json| JSON.parse(json) }
    post "/r/#{task.short_key}", params: { once: pass }
    expect(response).to have_http_status(:ok)
    expect(::Jil::Executor).to have_received(:async_call).with(
      user, task.code, { execute: true }, task: task, auth: :run, auth_id: user.id
    ).once

    post "/r/#{task.short_key}", params: { once: pass }
    expect(response).to have_http_status(:conflict)

    get "/r/#{task.short_key}", params: { once: pass }
    expect(response.body).not_to include("<script>")
    expect(::Jil::Executor).to have_received(:async_call).once
  end

  it "hands every open a fresh pass" do
    get "/r/#{task.short_key}"
    first = response.body[/pass=("[^"]+")/, 1]
    get "/r/#{task.short_key}"
    expect(response.body[/pass=("[^"]+")/, 1]).not_to eq(first)
  end

  it "refuses a pass for another task, and a made-up one" do
    other = user.tasks.create!(name: "Other", listener: "other", code: "")
    get "/r/#{other.short_key}"
    pass = JSON.parse(response.body[/pass=("[^"]+")/, 1])

    post "/r/#{task.short_key}", params: { once: pass }
    expect(response).to have_http_status(:gone)
    post "/r/#{task.short_key}", params: { once: "nope" }
    expect(response).to have_http_status(:gone)
    expect(::Jil::Executor).not_to have_received(:async_call)
  end

  context "when the task is shared with someone else" do
    let(:friend) { create(:user) }

    before do
      task.shared_tasks.create!(user: friend)
      delete "/logout"
      post "/login", params: { user: { username: friend.username, password: "password123" } }
    end

    it "opens their trigger page and runs on their scan, as the owner" do
      get "/t/#{task.short_key}"
      expect(response).to have_http_status(:ok)

      get "/r/#{task.short_key}"
      pass = JSON.parse(response.body[/pass=("[^"]+")/, 1])
      post "/r/#{task.short_key}", params: { once: pass }

      expect(response).to have_http_status(:ok)
      expect(::Jil::Executor).to have_received(:async_call).with(
        user, task.code, { execute: true }, task: task, auth: :run, auth_id: friend.id
      ).once
    end
  end

  it "finds nothing for someone it isn't shared with" do
    stranger = create(:user)
    delete "/logout"
    post "/login", params: { user: { username: stranger.username, password: "password123" } }

    get "/r/#{task.short_key}"
    expect(response).not_to have_http_status(:ok)
    expect(::Jil::Executor).not_to have_received(:async_call)
  end

  it "answers a prefetch with nothing" do
    get "/r/#{task.short_key}", headers: { "Sec-Purpose" => "prefetch;prerender" }
    expect(response).to have_http_status(:no_content)
  end

  it "does not auto-run a task that needs inputs" do
    task.update!(listener: "function(name:String)")
    get "/r/#{task.short_key}"
    expect(response.body).not_to include("<script>")
  end
end
