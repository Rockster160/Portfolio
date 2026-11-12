require "rails_helper"

RSpec.describe "Production scripts", type: :request do
  let(:user) { User.me }
  let(:head) { `git -C #{Rails.root} rev-parse HEAD`.strip }
  let(:build) { FeatureBuild.create!(user: user, title: "Yelling", request: "yell", status: :running) }
  let(:code) {
    <<~RUBY
      CODE = <<~'JIL'.strip
        done = Buddy.yell("key", "hi", {})::Boolean
      JIL
      puts CODE
    RUBY
  }
  let(:script) {
    ProductionScripts.create!(
      user: user, title: "Add the yell", code: code, commit_sha: head, edited_by: :mini, feature_build: build,
    )
  }

  before { allow(ProductionScriptRunWorker).to receive(:perform_async) }

  describe "from the Mini" do
    before {
      allow(ByteLocal).to receive(:valid_secret?).and_return(false)
      allow(ByteLocal).to receive(:valid_secret?).with("shh").and_return(true)
    }

    it "takes a new script for a build, waiting on approval, and answers with its page" do
      post "/webhooks/byte/production_scripts",
        params:  { build_id: build.id, title: "Add the yell", code: code, commit_sha: head },
        as:      :json,
        headers: { "X-Byte-Secret" => "shh" }

      created = ProductionScript.last
      expect(response.parsed_body).to include("ok" => true, "id" => created.id, "status" => "pending")
      expect(response.parsed_body["url"]).to end_with("/system/production_scripts/#{created.id}")
      expect(created).to have_attributes(feature_build: build, user: user, edited_by: "mini")
    end

    it "takes the approval away when it changes the script" do
      script.update!(status: :approved, approved_at: Time.current)

      patch "/webhooks/byte/production_scripts/#{script.id}",
        params:  { code: "puts 3" },
        as:      :json,
        headers: { "X-Byte-Secret" => "shh" }

      expect(script.reload).to be_status_pending
      expect(script.code).to eq("puts 3")
    end

    it "is turned away without the Mac's secret" do
      post "/webhooks/byte/production_scripts", params: { code: "puts 1", commit_sha: head }, as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(ProductionScript.count).to eq(0)
    end

    it "says why it won't take a script with no commit" do
      post "/webhooks/byte/production_scripts",
        params:  { build_id: build.id, title: "x", code: "puts 1", commit_sha: "" },
        as:      :json,
        headers: { "X-Byte-Secret" => "shh" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("Commit sha")
    end
  end

  describe "on the System pages" do
    def sign_in
      user.update!(password: "password123", password_confirmation: "password123")
      post login_path, params: { user: { username: user.username, password: "password123" } }
    end

    before { sign_in }

    it "counts what's waiting or failed on the System page" do
      script
      ProductionScripts.create!(user: user, title: "Old", code: "1", commit_sha: head, edited_by: :mini).update!(status: :succeeded)

      get system_path

      expect(response.body).to match(/Production Scripts.*?system-card-blip[^>]*>\s*1\s*</m)
    end

    it "shows the code with its heredoc set apart and checked" do
      get system_production_script_path(script)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("ps-heredoc ps-jil")
      expect(response.body).to include("ps-check ps-valid")
      expect(response.body).to include("waiting on approval")
    end

    it "approves it, and runs it at once when its commit is live" do
      post system_production_script_approve_path(script)

      expect(script.reload).to be_status_approved
      expect(ProductionScriptRunWorker).to have_received(:perform_async).with(script.id)
    end

    it "takes the approval away when the owner edits it too" do
      script.update!(status: :approved, approved_at: Time.current)

      patch system_production_script_path(script), params: { title: "Add the yell", code: "puts 4\r\n" }

      expect(script.reload).to be_status_pending
      expect(script.code).to eq("puts 4\n")
      expect(script.edited_by).to eq("owner")
    end

    it "writes one by hand, needing the running commit unless told otherwise" do
      get system_new_production_script_path
      expect(response.body).to include(%(value="#{head}"))

      post system_production_scripts_path, params: { title: "Mine", code: "puts 1\r\n", commit_sha: "" }

      created = ProductionScript.last
      expect(response).to redirect_to(system_production_script_path(created))
      expect(created).to have_attributes(
        title: "Mine", code: "puts 1\n", commit_sha: head, edited_by: "owner", status: "pending",
      )
    end

    it "keeps what was typed when it can't save it" do
      post system_production_scripts_path, params: { title: "Mine", code: "puts 1", commit_sha: "nope" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("puts 1", "Commit sha is invalid")
      expect(ProductionScript.count).to eq(0)
    end

    it "skips one, and brings it back" do
      post system_production_script_skip_path(script)
      expect(script.reload).to be_status_skipped

      post system_production_script_restore_path(script)
      expect(script.reload).to be_status_pending
    end
  end
end
