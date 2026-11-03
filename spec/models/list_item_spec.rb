require "rails_helper"

RSpec.describe ListItem do
  # What a list-item trigger carries, and therefore what a listener can filter
  # on. Jil::ListenerMatch can only tell you a listener PARSES, never that its
  # keys exist in the payload. The model helpers and both list-item controllers
  # all serialize through `jil_serialize`, so this covers all of them.
  describe "the jil payload" do
    let(:user)    { create(:user) }
    let(:list)    { create(:list, name: "Claude", user: user) }
    let!(:backend) { create(:section, list: list, name: "Ocs-Backend") }
    let!(:other)   { create(:section, list: list, name: "Portfolio") }

    def payload_for(section)
      create(:list_item, list: list, name: ">qa-scoring Done", section: section).jil_serialize(action: :added)
    end

    # Rails drops a nil association from `include`, so the key is absent
    # rather than null.
    it "nests the section by name beside the list, and leaves it out when there is none" do
      payload = payload_for(backend)

      expect(payload["section"]).to include("id" => backend.id, "name" => "Ocs-Backend")
      expect(payload["list"]).to include("name" => "Claude")
      expect(payload_for(nil)).not_to have_key("section")
    end

    it "lets a section watch fire only for that section, and a list watch for anything on the list" do
      watch = "item:action:added item:list:name:/^Claude$/ item:section:name:/^Ocs-Backend$/"
      broad = "item:action:added item:list:name:/^Claude$/"
      fires = ->(listener, section) { Jil::ListenerMatch.call(listener, :item, payload_for(section)) }

      expect(fires.call(watch, backend)).to be(true)
      expect(fires.call(watch, other)).to be(false)
      expect(fires.call(watch, nil)).to be(false)
      expect(fires.call(broad, nil)).to be(true)
      expect(fires.call(broad, other)).to be(true)
    end
  end

  # Item creation/removal through model paths (Jil List.add/toggle/remove, SMS,
  # recipes, webhooks, list builders) must emit the same `:item` Jil trigger the
  # list controllers fire for UI/API adds — attributed to the list owner.
  describe "jil :item triggers from model paths" do
    let(:user) { create(:user) }
    let(:list) { create(:list, user: user) }
    let(:fired) { [] }

    before {
      allow(::Jil).to receive(:trigger) { |u, scope, data, **|
        fired << [u, scope, data.with_indifferent_access]
      }
    }

    def last_fire = fired.last

    it "fires :item added attributed to the list owner, from .add and List#add_items" do
      item = list.list_items.add("Milk")

      u, scope, data = last_fire
      expect(u).to eq(user)
      expect(scope).to eq(:item)
      expect(data[:action]).to eq(:added)
      expect(data[:name]).to eq("Milk")
      expect(data.dig(:list, :name)).to eq(list.name)
      expect(item).to be_persisted

      list.add_items(name: "Eggs")
      expect(last_fire[2]).to include(action: :added, name: "Eggs")
    end

    describe "List#ensure_item" do
      it "leaves an item already on the list untouched and silent" do
        item = list.ensure_item("Back Left tire pressure low")
        stamp = item.reload.updated_at
        fired.clear

        expect(list.ensure_item("Back Left tire pressure low")).to eq(item)
        expect(item.reload.updated_at).to eq(stamp)
        expect(fired).to be_empty
      end

      it "adds it back once it has been checked off" do
        item = list.ensure_item("Back Left tire pressure low")
        list.list_items.remove(item.name)
        fired.clear

        list.ensure_item("Back Left tire pressure low")

        expect(item.reload).not_to be_deleted
        expect(last_fire[2][:action]).to eq(:added)
      end
    end

    # Two deliveries of the same add arriving together must not both miss the
    # row and both create it — the lookup runs under the list's row lock.
    describe "adding under the list lock" do
      def list_locks
        sql = []
        callback = ->(*, payload) { sql << payload[:sql] if payload[:sql].match?(/FROM "lists".*FOR UPDATE/m) }
        ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
        sql
      end

      it "locks the list for .add and .by_name_then_update" do
        expect(list_locks { list.list_items.add("Milk") }).to be_one
        expect(list_locks { list.add_items(name: "Eggs") }).to be_one
      end

      it "still reuses the existing row" do
        first = list.list_items.add("Milk")
        list.list_items.add("milk")
        list.add_items(name: "Milk")

        expect(list.list_items.pluck(:id)).to eq([first.id])
      end
    end

    it "fires removed from .remove, and added/removed/added from .toggle" do
      list.list_items.add("Bread")
      list.list_items.remove("Bread")
      expect(last_fire[2]).to include(action: :removed, name: "Bread")

      actions = 3.times.map {
        list.list_items.toggle("Soda")
        last_fire[2][:action]
      }
      expect(actions).to eq(%i[added removed added])
    end

    it "fires once per owner when the list is co-owned" do
      co_owner = create(:user)
      create(:user_list, user: co_owner, list: list, is_owner: true)

      list.list_items.add("Shared")

      owners_fired = fired.select { |_u, scope, data| scope == :item && data[:name] == "Shared" }
      expect(owners_fired.map(&:first)).to contain_exactly(user, co_owner)
    end

    it "does NOT fire for a mere collaborator (non-owner)" do
      collaborator = create(:user)
      create(:user_list, user: collaborator, list: list, is_owner: false)

      list.list_items.add("Milk")

      expect(fired.map(&:first)).to contain_exactly(user)
    end

    it "does NOT fire for an ownerless list or a blank name that never persists" do
      List.create!(name: "Orphan").list_items.add("Ghost")
      list.list_items.add("")
      expect(fired).to be_empty
    end
  end

  # Every commit broadcasts the WHOLE list, so a snapshot that describes the
  # list as it was a moment ago is a page that shows the list as it was a
  # moment ago, with no sign that anything is missing.
  describe "broadcasting" do
    let(:user) { create(:user) }
    let(:list) { create(:list, user: user) }

    def json_broadcasts
      sent = []
      allow(ActionCable.server).to receive(:broadcast) { |channel, data|
        sent << data if channel.to_s == "list_#{list.id}_json_channel"
      }
      yield
      sent
    end

    # A Jil task can hold one List and call `add` on it several times. The
    # first add loads `list_items` and the association memoizes, so later
    # snapshots must not broadcast that first read.
    it "reads the database, not the collection it loaded before the writes" do
      names = ["Pickup Whisper Dinner", "Kitchen & Living 90% Reset", "Dish washer running/delay"]
      names.each { |n| list.list_items.add(n) }
      list.list_items.each(&:soft_destroy)

      reused = List.find(list.id)
      sent = json_broadcasts { names.each { |n| reused.add(n) } }

      expect(sent.map { |d| d[:list_data][:items].length }).to eq([1, 2, 3])
      expect(sent.last[:list_data][:items].pluck(:name)).to match_array(names)
    end

    it "reads the database when a section changes too" do
      list.list_items.add("Milk")
      reused = List.find(list.id)
      reused.serialize # memoize everything the snapshot reads

      sent = json_broadcasts { create(:section, list: reused, name: "Dairy") }

      expect(sent.last[:list_data][:sections].pluck(:name)).to eq(["Dairy"])
    end

    it "stamps every snapshot, in the order the snapshots were read" do
      sent = json_broadcasts {
        list.list_items.add("One")
        list.list_items.add("Two")
        list.list_items.add("Three")
      }

      stamps = sent.pluck(:timestamp)

      expect(sent.map { |d| d[:list_data][:items].length }).to eq([1, 2, 3])
      expect(stamps).to eq(stamps.sort)
      expect(stamps.uniq.length).to eq(3)
    end

    it "still broadcasts the item's own channel alongside the list's" do
      channels = []
      allow(ActionCable.server).to receive(:broadcast) { |channel, _data| channels << channel }

      item = list.list_items.add("Solo")

      expect(channels).to include(
        "list_item_#{item.id}_channel",
        "list_#{list.id}_json_channel",
        "list_#{list.id}_html_channel",
      )
    end
  end

  # Clearing a row off the owner's Claude list tells terminal-pet the session
  # was seen. The hooks' own delete-and-repost on every state change must not.
  describe "acking the pet" do
    let(:list)     { create(:list, name: "Claude", user: User.me) }
    let(:section)  { create(:section, list: list, name: "Portfolio") }

    before { allow(PetWorker).to receive(:tell) }

    def remove(name, section: self.section, quiet: false)
      item = create(:list_item, list: list, name: name, section: section)
      item.quiet_for_pet = quiet
      item.soft_destroy
    end

    it "acks the label and the section, without the > or any state the hooks write", :aggregate_failures do
      remove(">memory Done")
      expect(PetWorker).to have_received(:tell).with(:ack, ["memory"], ["Portfolio"])

      ["…", "...", "Permission", "Error", "Rate limited", "Stopped", "Stalled"].each { |state|
        remove(">keyb #{state}")
      }
      expect(PetWorker).to have_received(:tell).with(:ack, ["keyb"], ["Portfolio"]).exactly(7).times

      remove(">abandon Done")
      expect(PetWorker).to have_received(:tell).with(:ack, ["abandon"], ["Portfolio"])

      remove(">solo Done", section: nil)
      expect(PetWorker).to have_received(:tell).with(:ack, ["solo"], [])
    end

    it "acks when the box is checked" do
      item = create(:list_item, list: list, name: ">memory Done", section: section)
      item.checked = "true"

      expect(PetWorker).to have_received(:tell).with(:ack, ["memory"], ["Portfolio"])
    end

    it "says nothing for the hooks' own replacement, an empty name, or anyone else's list" do
      remove(">memory …", quiet: true)
      remove(">Done")
      create(:list_item, list: create(:list, name: "Groceries", user: User.me), name: ">memory Done").soft_destroy
      create(:list_item, list: create(:list, name: "Claude", user: create(:user)), name: ">memory Done").soft_destroy

      expect(PetWorker).not_to have_received(:tell)
    end
  end
end
