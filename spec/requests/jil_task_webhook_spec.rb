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

  # A service like GitHub can sign its body but can't log in. A task listening
  # on webhook:public takes it with no credentials, and has to check the
  # signature itself from what it's handed.
  describe "a webhook:public task" do
    let(:secret) { "shared-secret" }
    let!(:public_task) {
      user.tasks.create!(
        name:     "Signed Hook",
        listener: "webhook:public",
        enabled:  true,
        code:     <<~'JIL',
          input = Global.input_data()::Hash
          headers = input.get("headers")::Hash
          rawBody = input.get("body")::String
          digest = rawBody.hmac("shared-secret")::String
          expected = String.new("sha256=#{digest}")::String
          given = headers.get("x-hub-signature-256")::String
          event = headers.get("x-github-event")::String
          signed = Boolean.eq(given, expected)::Boolean
          out = Global.return("#{event} #{signed}")::String
        JIL
      )
    }

    def post_signed(uuid, body, key: secret, headers: {})
      signature = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", key, body)}"
      post(
        "/jil/#{uuid}",
        params:  body,
        headers: {
          "CONTENT_TYPE"        => "application/json",
          "X-GitHub-Event"      => "push",
          "X-Hub-Signature-256" => signature,
        }.merge(headers),
      )
      response.parsed_body
    end

    it "runs with no credentials, handing the task the headers and the exact body" do
      body = post_signed(public_task.uuid, '{"b": 1,  "a": [2]}')

      expect(body).to eq("data" => "push true")
      expect(public_task.reload.last_execution.auth_type).to eq("webhook")
    end

    it "lets the task tell a forged signature apart" do
      expect(post_signed(public_task.uuid, "{}", key: "wrong")["data"]).to eq("push false")
    end

    it "keeps credentials out of the headers it hands over" do
      code = <<~JIL
        input = Global.input_data()::Hash
        headers = input.get("headers")::Hash
        keys = headers.keys()::Array
        out = Global.return(keys)::Array
      JIL
      public_task.update!(code: code)

      keys = post_signed(public_task.uuid, "{}", headers: { "Cookie" => "x=1" })["data"]
      expect(keys).to include("x-github-event")
      expect(keys).not_to include("cookie", "authorization")
    end

    it "still refuses an anonymous request for any other task" do
      post_signed(task.uuid, "{}")

      expect(response).to have_http_status(:no_content)
    end
  end
end
