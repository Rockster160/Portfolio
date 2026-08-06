require "rails_helper"

# Reporting a bad reply from the message's own long-press menu. The line lands
# on the Todo list as `#{id} [{body}] {description}`, which is the format asked
# for and also, not coincidentally, one that survives ListItem.add.
RSpec.describe ByteController, type: :controller do
  let(:rocco) { User.me }
  let(:convo) { rocco.byte_conversations.create!(mode: :buddy, name: "Byte", last_message_at: Time.current) }

  # jarvis_spec.rb builds a "TODO" list in a before(:context), which never rolls
  # back and so is visible to the whole suite run. Clear the field first so this
  # file owns the only match and isn't asserting against a leaked one.
  let!(:todo) {
    rocco.lists.ilike(name: "Todo").destroy_all
    List.create!(name: "Todo").tap { |l| UserList.create!(user: rocco, list: l, is_owner: true) }
  }

  def message(body)
    convo.byte_messages.create!(user: rocco, direction: :inbound, state: :delivered, body: body)
  end

  def items = todo.reload.list_items.map(&:name)

  before do
    allow(ByteLocal).to receive(:deliver).and_return(nil)
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(ActionCable.server).to receive(:broadcast)
    sign_in rocco
  end

  describe "POST #report_message" do
    it "files the id, the body and the description onto Todo" do
      msg = message("The plunge is at 4:45 AM.")

      post :report_message, params: { id: msg.id, description: "wrong timezone again" }

      expect(response).to be_successful
      expect(response.parsed_body["list"]).to eq("Todo")
      expect(items).to include("##{msg.id} [The plunge is at 4:45 AM.] wrong timezone again")
    end

    it "files without a description when the person left the box empty" do
      msg = message("Nope.")

      post :report_message, params: { id: msg.id, description: "" }

      expect(items).to include("##{msg.id} [Nope.]")
    end

    # The id has to lead. ListItem.add pulls a leading `[Section]` off the name
    # and files the row under it, so a line that opened with the quoted body
    # would have the body silently removed from what you see.
    it "keeps the quoted body out of the section-prefix position" do
      msg = message("Deploy finished successfully.")

      post :report_message, params: { id: msg.id, description: "it failed" }

      line = items.find { |n| n.include?("Deploy finished") }
      expect(line).to start_with("##{msg.id} [")
      expect(line).to include("Deploy finished successfully.")
    end

    it "truncates a long body but keeps the description whole" do
      msg = message("word " * 60)

      post :report_message, params: { id: msg.id, description: "rambling" }

      line = items.last
      expect(line).to end_with("rambling")
      expect(line).to include("...")
      expect(line.length).to be < 160
    end

    # A multi-line reply is the common case for a bad Buddy answer, and a list
    # item is one line.
    it "flattens newlines" do
      msg = message("Here you go:\n\n- one\n- two")

      post :report_message, params: { id: msg.id, description: "" }

      expect(items.last).to eq("##{msg.id} [Here you go: - one - two]")
    end

    # The body comes off the record, never off the client. The bubble's
    # data-full-body is editable by anything on the page.
    it "ignores a body supplied by the caller" do
      msg = message("what was actually said")

      post :report_message, params: { id: msg.id, description: "x", body: "what I claim was said" }

      expect(items.last).to include("what was actually said")
      expect(items.last).not_to include("what I claim was said")
    end

    it "refuses a message belonging to someone else" do
      other = create(:user)
      theirs = other.byte_conversations.create!(mode: :buddy, last_message_at: Time.current)
      msg = theirs.byte_messages.create!(user: other, direction: :inbound, state: :delivered, body: "hi")

      post :report_message, params: { id: msg.id, description: "x" }

      expect(response).to have_http_status(:not_found)
      expect(items).to be_empty
    end

    it "picks the oldest when more than one Todo list exists" do
      newer = List.create!(name: "TODO")
      UserList.create!(user: rocco, list: newer, is_owner: true)
      msg = message("hi")

      post :report_message, params: { id: msg.id, description: "x" }

      expect(items.last).to include("##{msg.id}")
      expect(newer.reload.list_items).to be_empty
    end

    it "says so rather than 500ing when there is no Todo list" do
      msg = message("hi")
      todo.destroy!

      post :report_message, params: { id: msg.id, description: "x" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["errors"].first).to include("Todo")
    end
  end
end
