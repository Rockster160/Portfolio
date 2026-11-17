require "rails_helper"

RSpec.describe PrettyLoggerSlices do
  def logged(path, params, headers={})
    request = instance_double(
      ActionDispatch::Request,
      path:                path,
      headers:             headers,
      request_parameters:  params.as_json,
      filtered_parameters: params.with_indifferent_access.except(:action),
    )
    PrettyLogger::RequestLogger.new(request: request).params.as_json.deep_symbolize_keys
  end

  it "keeps only what says what happened on a GitHub push, with the event" do
    shown = logged(
      "/webhooks/github",
      {
        ref:         "refs/heads/master",
        after:       "cbad716",
        repository:  { id: 1, owner: { avatar_url: "https://x", login: "Rockster160" } },
        head_commit: { message: "Better naming", tree_id: "abc", author: { email: "a@b" } },
        sender:      { login: "Rockster160", avatar_url: "https://x" },
      },
      { "X-GitHub-Event" => "push" },
    )

    expect(shown).to eq(
      event:       "push",
      ref:         "refs/heads/master",
      after:       "cbad716",
      head_commit: { message: "Better naming" },
      sender:      { login: "Rockster160" },
    )
  end

  it "keeps a workflow job's name and where it got to" do
    shown = logged(
      "/webhooks/github",
      {
        action:       "completed",
        workflow_job: { id: 1, name: "deploy", status: "completed", conclusion: "success", steps: [{ name: "x" }] },
      },
      { "X-GitHub-Event" => "workflow_job" },
    )

    expect(shown).to eq(
      event:        "workflow_job",
      action:       "completed",
      workflow_job: { name: "deploy", status: "completed", conclusion: "success" },
    )
  end

  it "keeps only the fields a Tesla telemetry record changed" do
    shown = logged(
      "/webhooks/tesla_telemetry",
      {
        msg:      "record_payload",
        data:     { CreatedAt: "2026-11-17T18:07:26Z", IsResend: false, VehicleSpeed: 34, Vin: "5YJ3E1EA9NF355991" },
        metadata: { txid: "53f7f0cf", receivedat: "1794938846660" },
        context:  "fleet-telemetry",
        vin:      "5YJ3E1EA9NF355991",
      },
    )

    expect(shown).to eq(VehicleSpeed: 34)
  end

  it "says a Tesla record was resent, and reduces a route to its length" do
    shown = logged(
      "/webhooks/tesla_telemetry",
      { msg: "record_payload", data: { IsResend: true, RouteLine: "a~b`c@d" * 300, Vin: "5YJ" } },
    )

    expect(shown).to eq(IsResend: true, RouteLine: "2100c polyline")
  end

  it "keeps what was said to Alexa and which Echo heard it" do
    shown = logged(
      "/api/v1/alexa",
      {
        version: "1.0",
        session: { new: true, sessionId: "amzn1.echo-api.session.364b", user: { userId: "amzn1.ask.account.AMA3" } },
        context: {
          System: {
            application: { applicationId: "amzn1.ask.skill.a405" },
            device:      { deviceId: "amzn1.ask.device.AMAX", supportedInterfaces: {} },
            apiEndpoint: "https://api.amazonalexa.com",
          },
        },
        request: {
          type:      "IntentRequest",
          requestId: "amzn1.echo-api.request.dd82",
          locale:    "en-US",
          intent:    {
            name:  "JarvisPhrases",
            slots: {
              control: { name: "control", value: "set", resolutions: { resolutionsPerAuthority: [] } },
              device:  { name: "device", value: "the garage to open" },
            },
          },
        },
      },
    )

    expect(shown).to eq(
      request: {
        type:   "IntentRequest",
        intent: { name: "JarvisPhrases", slots: { control: { value: "set" }, device: { value: "the garage to open" } } },
      },
      context: { System: { device: { deviceId: "amzn1.ask.device.AMAX" } } },
    )
  end

  it "keeps why an Alexa session ended badly" do
    error = { type: "INVALID_RESPONSE", message: "An exception occurred while dispatching the request to the skill." }
    shown = logged(
      "/api/v1/alexa",
      { request: { type: "SessionEndedRequest", requestId: "amzn1.x", reason: "ERROR", error: error } },
    )

    expect(shown).to eq(request: { type: "SessionEndedRequest", reason: "ERROR", error: error })
  end

  it "slices the same Tesla record when Jil logs it as a trigger" do
    payload = { msg: "record_payload", data: { CreatedAt: "x", Gear: "D", Vin: "5YJ" }, vin: "5YJ" }

    expect(described_class.for_trigger(:tesla, payload)).to eq(Gear: "D")
    expect(described_class.for_trigger(:email, payload)).to eq(payload)
  end

  it "leaves every other request whole" do
    expect(logged("/webhooks/battery", { level: 80, charging: true })).to eq(level: 80, charging: true)
  end
end
