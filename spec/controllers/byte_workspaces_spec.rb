require "rails_helper"

# Picking where a Claude/cursor/bash thread starts.
#
# Before this, cwd was Mac-authoritative with no way to set it: a new
# conversation had no directory at all until somebody typed `!cd`, and
# State::DEFAULT_CWD silently pointed every one of them at Portfolio.
RSpec.describe "Byte starting directory" do
  let(:rocco) { User.me }

  before do
    allow(ByteLocal).to receive_messages(deliver: nil, set_cwd: true)
    allow(MonitorChannel).to receive(:broadcast_to)
    DataStorage.where(name: ByteWorkspaces::KEY.to_s).delete_all
  end

  describe ByteWorkspaces do
    it "keeps the reported list and stamps when it arrived" do
      described_class.replace!(["~/code/Portfolio", "~/code/ocs-backend"])

      expect(described_class.all).to eq(["~/code/ocs-backend", "~/code/Portfolio"])
      expect(described_class.reported_at).to be_within(5.seconds).of(Time.current)
    end

    it "drops blanks, duplicates and trailing slashes" do
      described_class.replace!(["~/code/Byte/", "~/code/Byte", "", nil, "  "])

      expect(described_class.all).to eq(["~/code/Byte"])
    end

    # Typing "ocs" should offer the repo before twenty worktrees cut from it.
    # Alphabetical order puts a worktree first every single time.
    it "ranks an exact basename above a prefix above a substring" do
      described_class.replace!([
        "~/code/ocs-backend--rn-feature-recon",
        "~/code/ocs",
        "~/code/ocs-backend",
        "~/code/my-ocs-notes",
      ])

      expect(described_class.search("ocs")).to eq([
        "~/code/ocs",
        "~/code/ocs-backend",
        "~/code/ocs-backend--rn-feature-recon",
        "~/code/my-ocs-notes",
      ])
    end

    it "is case-insensitive" do
      described_class.replace!(["~/code/Portfolio"])

      expect(described_class.search("portf")).to eq(["~/code/Portfolio"])
    end

    it "returns the whole list for an empty query" do
      described_class.replace!(["~/code/a", "~/code/b"])

      expect(described_class.search("")).to eq(["~/code/a", "~/code/b"])
    end

    # A repo cloned since the last report is real. Refusing anything unknown
    # would make the picker worse than typing the path out.
    it "accepts a plausible path it has never heard of" do
      expect(described_class.plausible?("~/code/brand-new")).to be(true)
      expect(described_class.plausible?("/Users/zoro/code/thing")).to be(true)
    end

    it "rejects what can't be a directory" do
      expect(described_class.plausible?("")).to be(false)
      expect(described_class.plausible?("code/relative")).to be(false)
      expect(described_class.plausible?("~/code/../../etc")).to be(false)
    end
  end

  describe WebhooksController, type: :controller do
    it "takes the Mac's report" do
      request.headers["X-Byte-Secret"] = ENV.fetch("BYTE_LOCAL_SECRET", "")
      allow(controller).to receive(:byte_authorized?).and_return(true)

      post :byte_workspaces, params: { paths: ["~/code/Portfolio", "~/code/Byte"] }

      expect(response).to be_successful
      expect(ByteWorkspaces.all).to contain_exactly("~/code/Byte", "~/code/Portfolio")
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
      it "answers from the cache, with no call to the Mac" do
        ByteWorkspaces.replace!(["~/code/Portfolio", "~/code/ocs-backend"])

        get :workspaces, params: { q: "ocs" }

        expect(response.parsed_body["paths"]).to eq(["~/code/ocs-backend"])
        expect(ByteLocal).not_to have_received(:deliver)
      end

      it "hands back the default so the field can hint at it" do
        get :workspaces

        expect(response.parsed_body["default"]).to eq(ByteWorkspaces::DEFAULT)
      end
    end

    describe "POST #create_conversation" do
      it "stores the starting directory on a Mac-mode thread" do
        post :create_conversation, params: { name: "OCS", mode: "claude", cwd: "~/code/ocs-backend" }

        expect(rocco.byte_conversations.last.cwd).to eq("~/code/ocs-backend")
      end

      it "works for the new cursor mode too" do
        post :create_conversation, params: { name: "Agent", mode: "cursor", cwd: "~/code/ocs-backend" }

        convo = rocco.byte_conversations.last
        expect(convo.mode).to eq("cursor")
        expect(convo.cwd).to eq("~/code/ocs-backend")
      end

      # A Buddy thread has no shell and no filesystem, so a cwd on one is a
      # value nothing would ever read.
      it "ignores a directory on a thread that has no filesystem" do
        post :create_conversation, params: { name: "Chat", mode: "buddy", cwd: "~/code/ocs-backend" }

        expect(rocco.byte_conversations.last.cwd).to be_nil
      end

      it "ignores a path that can't be a directory" do
        post :create_conversation, params: { name: "Bad", mode: "claude", cwd: "../../etc" }

        expect(rocco.byte_conversations.last.cwd).to be_nil
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
        ByteWorkspaces.replace!(["~/code/ocs-backend"])

        expect(cd("~/code/ocs-backend")).to include("set to `~/code/ocs-backend`")
        expect(convo.reload.cwd).to eq("~/code/ocs-backend")
        expect(ByteLocal).to have_received(:set_cwd).with(conversation_id: convo.id, cwd: "~/code/ocs-backend")
      end

      # The record is the durable half. A directory chosen while the Mac is
      # asleep still has to be there when it wakes.
      it "still records it when the Mac doesn't answer" do
        allow(ByteLocal).to receive(:set_cwd).and_return(false)
        ByteWorkspaces.replace!(["~/code/ocs-backend"])

        expect(cd("~/code/ocs-backend")).to include("when it next wakes")
        expect(convo.reload.cwd).to eq("~/code/ocs-backend")
      end

      it "flags a directory the Mac has never reported, without refusing it" do
        ByteWorkspaces.replace!(["~/code/Portfolio"])

        expect(cd("~/code/brand-new")).to include("isn't one of the directories")
        expect(convo.reload.cwd).to eq("~/code/brand-new")
      end

      it "reports the current directory when given no argument" do
        convo.update!(metadata: { "cwd" => "~/code/Byte" })

        expect(cd("")).to include("currently `~/code/Byte`")
      end

      it "falls back to the shared default when nothing is set" do
        expect(cd("")).to include(ByteWorkspaces::DEFAULT)
      end

      it "refuses something that isn't a path" do
        expect(cd("not a path")).to include("doesn't look like a directory")
        expect(convo.reload.cwd).to be_nil
      end
    end

    describe "cursor mode" do
      it "is switchable with /mode" do
        convo = rocco.byte_conversations.create!(mode: :claude, last_message_at: Time.current)

        post :create_message, params: { conversation_id: convo.id, body: "/mode cursor" }

        expect(convo.reload.mode).to eq("cursor")
      end

      it "counts as a Mac mode, so it has a working directory" do
        convo = rocco.byte_conversations.create!(mode: :cursor, last_message_at: Time.current)

        expect(convo).to be_mac
        expect(ByteConversation::MAC_MODES).to include("cursor")
      end
    end
  end
end
