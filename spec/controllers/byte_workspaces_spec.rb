require "rails_helper"

# Picking where a Claude/bash thread starts.
RSpec.describe "Byte starting directory" do
  let(:rocco) { User.me }

  before do
    allow(ByteLocal).to receive_messages(deliver: nil, set_cwd: true)
    allow(MonitorChannel).to receive(:broadcast_to)
    DataStorage.where(name: ByteConversation.machines.keys.map { |m| ByteWorkspaces.key(m).to_s }).delete_all
  end

  describe ByteWorkspaces do
    it "keeps the reported list, stamped, without blanks, duplicates or trailing slashes" do
      described_class.replace!(
        ["~/code/Portfolio", "~/code/ocs-backend", "~/code/Portfolio/", "", nil, "  "],
        machine: :mini,
      )

      expect(described_class.all(:mini)).to eq(["~/code/ocs-backend", "~/code/Portfolio"])
      expect(described_class.reported_at(:mini)).to be_within(5.seconds).of(Time.current)
    end

    it "keeps each Mac's list apart" do
      described_class.replace!(["~/code/Portfolio"], machine: :mini)
      described_class.replace!(["~/code/jobhunt"], machine: :laptop)

      expect(described_class.search("", machine: :mini)).to eq(["~/code/Portfolio"])
      expect(described_class.search("", machine: :laptop)).to eq(["~/code/jobhunt"])
    end

    # Typing "ocs" should offer the repo before twenty worktrees cut from it.
    # Alphabetical order puts a worktree first every single time.
    it "ranks an exact basename above a prefix above a substring" do
      described_class.replace!([
        "~/code/ocs-backend--rn-feature-recon",
        "~/code/ocs",
        "~/code/ocs-backend",
        "~/code/my-ocs-notes",
      ], machine: :mini)

      expect(described_class.search("ocs", machine: :mini)).to eq([
        "~/code/ocs",
        "~/code/ocs-backend",
        "~/code/ocs-backend--rn-feature-recon",
        "~/code/my-ocs-notes",
      ])
    end

    it "searches case-insensitively, returning the whole list for an empty query" do
      described_class.replace!(["~/code/Portfolio", "~/code/b"], machine: :mini)

      expect(described_class.search("portf", machine: :mini)).to eq(["~/code/Portfolio"])
      expect(described_class.search("", machine: :mini)).to eq(["~/code/b", "~/code/Portfolio"])
    end

    # A repo cloned since the last report is real. Refusing anything unknown
    # would make the picker worse than typing the path out.
    it "accepts a plausible path it has never heard of and rejects what can't be a directory" do
      expect(described_class.plausible?("~/code/brand-new")).to be(true)
      expect(described_class.plausible?("/Users/zoro/code/thing")).to be(true)
      expect(described_class.plausible?("")).to be(false)
      expect(described_class.plausible?("code/relative")).to be(false)
      expect(described_class.plausible?("~/code/../../etc")).to be(false)
    end
  end

  describe WebhooksController, type: :controller do
    it "files each Mac's report under that Mac, and an unnamed one under the laptop" do
      allow(controller).to receive(:byte_authorized?).and_return(true)

      post :byte_workspaces, params: { paths: ["~/code/Portfolio", "~/code/Byte"], machine: "mini" }
      expect(response).to be_successful
      post :byte_workspaces, params: { paths: ["~/code/jobhunt"] }

      expect(ByteWorkspaces.all(:mini)).to contain_exactly("~/code/Byte", "~/code/Portfolio")
      expect(ByteWorkspaces.all(:laptop)).to eq(["~/code/jobhunt"])
    end

    it "refuses without the shared secret" do
      post :byte_workspaces, params: { paths: ["~/code/Portfolio"] }

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe ByteController, type: :controller do
    before { sign_in rocco }

    describe "GET #workspaces" do
      # The whole reason the list is cached rather than fetched: this modal is
      # opened from a phone, and the Mac is usually asleep.
      it "answers from the cache, with no call to the Mac, and hands back the default" do
        ByteWorkspaces.replace!(["~/code/Portfolio", "~/code/ocs-backend"], machine: :mini)

        get :workspaces, params: { q: "ocs", mode: "claude" }

        expect(response.parsed_body["paths"]).to eq(["~/code/ocs-backend"])
        expect(response.parsed_body["default"]).to eq(ByteWorkspaces::DEFAULT)
        expect(ByteLocal).not_to have_received(:deliver)
      end
    end

    describe "POST #create_conversation" do
      # A Buddy thread has no shell and no filesystem, so a cwd on one is a
      # value nothing would ever read.
      it "stores the starting directory only on a Mac-mode thread, and only a plausible one" do
        [
          ["claude", "~/code/ocs-backend", "~/code/ocs-backend"],
          ["bash", "~/code/ocs-backend", "~/code/ocs-backend"],
          ["buddy", "~/code/ocs-backend", nil],
          ["claude", "../../etc", nil],
        ].each do |mode, cwd, stored|
          post :create_conversation, params: { name: "T", mode: mode, cwd: cwd }

          convo = rocco.byte_conversations.order(:id).last
          expect(convo.mode).to eq(mode)
          expect(convo.cwd).to eq(stored), "#{mode} #{cwd}"
        end
      end

      it "leaves metadata alone when no directory was chosen" do
        post :create_conversation, params: { name: "Plain", mode: "claude" }

        expect(rocco.byte_conversations.last.metadata).to eq({})
      end
    end

    describe "/cd" do
      let(:convo) { rocco.byte_conversations.create!(mode: :claude, name: "Work", last_message_at: Time.current) }

      def cd(arg)
        post :create_message, params: { conversation_id: convo.id, body: "/cd #{arg}".strip }
        convo.byte_messages.order(:id).last.body
      end

      it "moves the directory and tells the Mac" do
        ByteWorkspaces.replace!(["~/code/ocs-backend"], machine: :mini)

        cd("~/code/ocs-backend")
        expect(convo.reload.cwd).to eq("~/code/ocs-backend")
        expect(ByteLocal).to have_received(:set_cwd).with(
          conversation_id: convo.id,
          cwd:             "~/code/ocs-backend",
          machine:         "mini",
        )
      end

      # The record is the durable half. A directory chosen while the Mac is
      # asleep still has to be there when it wakes; one it never reported is
      # still taken.
      it "still records it when the Mac doesn't answer, or has never reported it" do
        allow(ByteLocal).to receive(:set_cwd).and_return(false)
        ByteWorkspaces.replace!(["~/code/Portfolio"], machine: :mini)

        cd("~/code/brand-new")
        expect(convo.reload.cwd).to eq("~/code/brand-new")
      end

      it "reports the current directory when given no argument" do
        convo.update!(metadata: { "cwd" => "~/code/Byte" })

        expect(cd("")).to include("~/code/Byte")
      end

      it "falls back to the shared default when nothing is set" do
        expect(cd("")).to include(ByteWorkspaces::DEFAULT)
      end

      it "refuses something that isn't a path" do
        cd("not a path")
        expect(convo.reload.cwd).to be_nil
        expect(ByteLocal).not_to have_received(:set_cwd)
      end
    end

    describe "which Mac a thread runs on" do
      it "puts a shell thread on the laptop and moves it with its mode" do
        convo = rocco.byte_conversations.create!(mode: :bash, last_message_at: Time.current)
        expect(convo).to be_on_laptop

        post :create_message, params: { conversation_id: convo.id, body: "/mode claude" }

        expect(convo.reload).to be_on_mini
        expect(convo.byte_messages.order(:id).last.body).to include("the Mac Mini")
      end

      # A Claude thread can adopt a session started in a laptop terminal, which
      # only the laptop has on disk.
      it "moves a thread with /machine and drops the session it can't carry" do
        convo = rocco.byte_conversations.create!(
          mode:            :claude,
          last_message_at: Time.current,
          metadata:        { "claude_session_id" => "abc" },
        )
        allow(ByteLocal).to receive(:reset_claude_session).and_return(false)

        post :create_message, params: { conversation_id: convo.id, body: "/machine laptop" }

        convo.reload
        expect(convo).to be_on_laptop
        expect(convo.claude?).to be(true)
        expect(convo.metadata["claude_session_id"]).to be_nil
        expect(ByteLocal).to have_received(:reset_claude_session).with(
          conversation_id: convo.id,
          machine:         :laptop,
        )
      end

      it "refuses a Mac it doesn't know" do
        convo = rocco.byte_conversations.create!(mode: :claude, last_message_at: Time.current)

        post :create_message, params: { conversation_id: convo.id, body: "/machine desktop" }

        expect(convo.reload).to be_on_mini
        expect(convo.byte_messages.order(:id).last.body).to include("usage")
      end

      it "offers only the directories of the Mac the chosen mode runs on" do
        ByteWorkspaces.replace!(["~/code/Portfolio"], machine: :mini)
        ByteWorkspaces.replace!(["~/code/jobhunt"], machine: :laptop)

        get :workspaces, params: { mode: "bash" }

        expect(response.parsed_body["paths"]).to eq(["~/code/jobhunt"])
      end
    end
  end
end
