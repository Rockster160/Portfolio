require "rails_helper"

# Buddy reaching the Mac at the desk. Every request is stubbed - the point of
# the design is that only a NAME crosses the wire, so that's what these assert.
RSpec.describe "Buddy mac_command" do
  let(:user)  { create(:user) }
  let(:tool)  { Buddy::Tools[:mac_command] }
  let(:ctx)   { Buddy::ToolContext.new(user, proposal: { "payload" => { "command" => "dark_monitors" } }) }
  let(:url)   { "http://localhost:8788/byte/command" }

  before { allow(ByteLocal).to receive(:base_url).and_return("http://localhost:8788") }

  def stub_mac(status:, body:)
    stub_request(:post, url).to_return(status: status, body: JSON.generate(body), headers: { "Content-Type" => "application/json" })
  end

  it "sends the command name and nothing that resembles a shell string" do
    stub_mac(status: 200, body: { ok: true, name: "dark_monitors", output: "", exit_status: 0 })

    ByteLocal.run_command(:dark_monitors)

    expect(a_request(:post, url).with { |req|
      body = JSON.parse(req.body)
      body.keys == ["name"] && body["name"] == "dark_monitors"
    }).to have_been_made
  end

  it "refuses a name that isn't in the catalog before it ever leaves Rails" do
    expect { ByteLocal.run_command(:rm_rf_slash) }.to raise_error(/isn't a Mac command/)
    expect(a_request(:post, url)).not_to have_been_made
  end

  it "carries the Mac's own error text back" do
    stub_mac(status: 422, body: { ok: false, error: "timed out after 20s" })

    expect { ByteLocal.run_command(:dark_monitors) }.to raise_error(/timed out after 20s/)
  end

  describe "the tool" do
    # These are idempotent state commands, so a repeat in one turn is never a
    # second instruction.
    it "collapses the same command called twice in one turn" do
      key = tool[:merge_key]

      expect(key.call({ command: "dark_monitors" })).to eq(key.call({ command: :dark_monitors }))
      expect(key.call({ command: "dark_monitors" })).not_to eq(key.call({ command: "mac_ping" }))
    end

    it "only offers the commands the Mac actually has" do
      schema = Buddy::Tools.function_schema(tool)

      expect(schema[:parameters][:properties][:command][:enum]).to eq(ByteLocal::MAC_COMMANDS.keys)
    end

    it "builds its schema without ever asking the Mac what it can do" do
      # The registry is a Rails constant on purpose. Discovering it over HTTP
      # would put a round trip — to a machine that might be asleep — in front of
      # every turn, including the ones that never touch it.
      Buddy::Tools.function_schemas

      expect(a_request(:any, /localhost:8788/)).not_to have_been_made
    end

    it "gives up on an unreachable Mac at the timeout" do
      stub_request(:post, url).to_return { sleep 0.2 }
      stub_const("ByteLocal::COMMAND_TIMEOUT_SECONDS", 0.05)

      started = Time.current
      expect { ByteLocal.run_command(:dark_monitors) }.to raise_error(/couldn't reach the Mac/)
      expect(Time.current - started).to be < 1
    end

    it "rejects a command outside the enum" do
      _payload, errors = Buddy::Tools.validate_payload(tool, { command: "reboot" })

      expect(errors).to be_present
    end

    it "reports the failure instead of the chip claiming it happened" do
      stub_request(:post, url).to_timeout

      result = Buddy::Tools.dispatch(tool, { command: :dark_monitors }, ctx)

      expect(result[:ok]).to be(false)
      expect(result[:error]).to include("couldn't reach the Mac")
    end

    it "puts what the Mac said on the receipt when it said anything" do
      stub_mac(status: 200, body: { ok: true, name: "mac_ping", output: "awake on Zoro at 11:40 AM", exit_status: 0 })
      ping_ctx = Buddy::ToolContext.new(user, proposal: { "payload" => { "command" => "mac_ping" } })

      result = Buddy::Tools.dispatch(tool, { command: :mac_ping }, ping_ctx)

      expect(result[:ok]).to be(true)
      expect(tool[:receipt].call(result[:data], ping_ctx)).to include("awake on Zoro at 11:40 AM")
    end
  end
end
