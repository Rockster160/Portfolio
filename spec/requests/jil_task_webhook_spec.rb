require "rails_helper"

# `GET /jil/<uuid>` runs one Jil task by uuid and answers with what it returned.
#
# It's the READ side of the integrations that otherwise only push: Home
# Assistant posts sensor events all day and gets `head :ok` back, so a task is
# the only way for it to ASK a question and hear an answer. The before-bed
# boolean is the case that made it matter — HASS needs to be able to resync
# without waiting for the next thing to change on the list.
#
# `force: true` in the controller is what makes a `function()` task reachable
# here at all: nothing about a GET matches a function signature, so without it
# the listener check would refuse every one of them.
RSpec.describe "Running a Jil task over HTTP" do
  let(:user) { create(:user) }
  let!(:api_key) { ApiKey.create!(user: user, name: "HASS") }
  let!(:task) {
    user.tasks.create!(
      name:     "Answer Something",
      listener: "function()::Numeric",
      enabled:  true,
      code:     <<~'JIL',
        answer = Numeric.new(7)::Numeric
        out = Global.return(answer)::Numeric
      JIL
    )
  }

  def get_task(uuid, token: api_key.key)
    get("/jil/#{uuid}", headers: { "HTTP_AUTHORIZATION" => "Bearer #{token}" })
    response.parsed_body
  end

  it "runs the task and hands back its return value" do
    expect(get_task(task.uuid)["data"]).to eq(7)
  end

  it "names the task it ran, so a caller can tell which answered" do
    expect(get_task(task.uuid).dig("task", "name")).to eq("Answer Something")
  end

  # A POST body does NOT arrive where a `/jil/trigger/<scope>` body arrives.
  # `execute_task` wraps it — `match_run(:webhook, { params: json_params })` —
  # so a task written for the trigger door reads nil here, and nil casts to ""
  # rather than raising. Every way that goes wrong is silent, so it's pinned.
  it "delivers a POST body nested under params, alongside the uuid" do
    seen = nil
    allow_any_instance_of(Jil::Methods::Global).to(
      receive(:execute).and_wrap_original { |orig, line|
        seen ||= orig.receiver.instance_variable_get(:@jil).input_data if line.methodname == :input_data
        orig.call(line)
      },
    )
    task.update!(code: "data = Global.input_data()::Hash\n")

    post(
      "/jil/#{task.uuid}",
      params:  { direction: "open" }.to_json,
      headers: {
        "HTTP_AUTHORIZATION" => "Bearer #{api_key.key}",
        "CONTENT_TYPE"       => "application/json",
      },
    )

    expect(seen[:direction]).to be_nil
    expect(seen.dig(:params, :direction)).to eq("open")
    expect(seen.dig(:params, :uuid)).to eq(task.uuid)
  end

  it "says so rather than guessing when the uuid names nothing" do
    body = get_task(SecureRandom.uuid)

    expect(response).to have_http_status(:not_found)
    expect(body["data"]).to be_nil
  end

  # The token is the whole door. Without it this would run anybody's task.
  it "refuses a request carrying no credentials" do
    get "/jil/#{task.uuid}"

    expect(response).to have_http_status(:no_content)
  end

  it "refuses a task belonging to someone else" do
    other = create(:user)
    other_key = ApiKey.create!(user: other, name: "Theirs")

    expect(get_task(task.uuid, token: other_key.key)["data"]).to be_nil
    expect(response).to have_http_status(:not_found)
  end
end
