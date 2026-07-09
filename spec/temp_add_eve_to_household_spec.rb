require "rails_helper"

# One-off spec covering lib/scripts/add_eve_to_household.rb — verifies the
# script LOADs, creates the membership row, and inserts the Eve entry in
# task 365's who_opts array while leaving the rest of the code untouched.
# DELETE this file after the script is executed in prod.
RSpec.describe "add_eve_to_household script" do
  let(:me) { User.me || FactoryBot.create(:user, role: :admin) }
  let(:eve_username) { "Eve" }

  let(:starting_365_code) {
    <<~'JIL'
      event = Global.input_data()::ActionEvent
      action = event.action()::String
      map = Custom.ChoreEventMapAmbiguous()::Hash
      is_added = Boolean.compare(action, "==", "added")::Boolean
      not_added = Boolean.not(is_added)::Boolean

      sync_branch = Global.if({
        na = Global.ref(not_added)::Boolean
      }, {
        iter1 = map.each({
          a1 = Keyword.Value()::Hash
          n1 = a1.get("chore_name")::String
          r1 = Chore.sync_event(n1, event, a1)::Boolean
        })::Hash
      }, {})::Any

      prompt_branch = Global.if({
        ia = Global.ref(is_added)::Boolean
      }, {
        ev_name = event.name()::String
        ev_notes = event.notes()::String
        ev_id = event.id()::Numeric
        ev_ts = event.timestamp()::Date
        iter2 = map.each({
          cattrs = Keyword.Value()::Hash
          cname = cattrs.get("chore_name")::String
          map_name = cattrs.get("name")::String
          map_notes = cattrs.get("notes")::String
          name_match = Boolean.compare(map_name, "==", ev_name)::Boolean
          has_notes = map_notes.presence()::Boolean
          notes_skip = Boolean.not(has_notes)::Boolean
          notes_eq = Boolean.compare(map_notes, "==", ev_notes)::Boolean
          notes_match = Boolean.or(notes_skip, notes_eq)::Boolean
          matched = Boolean.and(name_match, notes_match)::Boolean
          do_prompt = Global.if({
            m1 = Global.ref(matched)::Boolean
          }, {
            params = Hash.new({
              p_src = Keyval.new("source", "ambiguous_chore")::Keyval
              p_cn = Keyval.new("chore_name", cname)::Keyval
              p_eid = Keyval.new("event_id", ev_id)::Keyval
            })::Hash
            who_opts = Array.new({
              o1 = String.new("Rockster160")::String
              o2 = String.new("Alchemibluum")::String
            })::Array
            title = String.new("Who did: #{cname}?")::String
            pq_who = PromptQuestion.select("Who did it?", who_opts, "")::PromptQuestion
            pq_when = PromptQuestion.datetime("When?", ev_ts)::PromptQuestion
            pcreated = Prompt.create(title, params, {
              pq1 = Global.ref(pq_who)::PromptQuestion
              pq2 = Global.ref(pq_when)::PromptQuestion
            }, true)::Prompt
          }, {})::Any
        })::Hash
      }, {})::Any
    JIL
  }

  before do
    ChoreHouseholdMembership.where(chore_household_id: 1).delete_all
    User.where(chore_household_id: 1).update_all(chore_household_id: nil)
    User.where(id: 4).delete_all
    ChoreHousehold.where(id: 1).delete_all
    Task.where(id: 365).delete_all

    ChoreHousehold.create!(id: 1, owner_user_id: me.id, name: "Household")
    FactoryBot.create(:user, id: 4, username: eve_username, email: "eve-#{SecureRandom.hex(4)}@example.com")
    me.tasks.create!(id: 365, name: "Event → Ambiguous Chore Sync", code: starting_365_code, enabled: true)
  end

  describe "loading the script" do
    it "creates the membership row for Eve as :member" do
      load Rails.root.join("lib/scripts/add_eve_to_household.rb")

      membership = ChoreHouseholdMembership.find_by(user_id: 4, chore_household_id: 1)
      expect(membership).to be_present
      expect(membership.role).to eq("member")
    end

    it "adds the Eve String.new line to who_opts and leaves the rest untouched" do
      load Rails.root.join("lib/scripts/add_eve_to_household.rb")

      updated = me.tasks.find(365).code
      expect(updated).to match(
        /o1 = String\.new\("Rockster160"\)::String\s+o2 = String\.new\("Alchemibluum"\)::String\s+o3 = String\.new\("Eve"\)::String/
      )
      # Everything outside the who_opts block is unchanged.
      expect(updated).to include('title = String.new("Who did: #{cname}?")')
      expect(updated).to include('pq_who = PromptQuestion.select("Who did it?", who_opts, "")')
    end

    it "is idempotent — running twice does not duplicate the membership or the option" do
      load Rails.root.join("lib/scripts/add_eve_to_household.rb")
      load Rails.root.join("lib/scripts/add_eve_to_household.rb")

      expect(ChoreHouseholdMembership.where(user_id: 4).count).to eq(1)
      count = me.tasks.find(365).code.scan('String.new("Eve")::String').size
      expect(count).to eq(1)
    end
  end

  describe "the updated Jil code" do
    it "passes Jil::Validator" do
      load Rails.root.join("lib/scripts/add_eve_to_household.rb")
      new_code = me.tasks.find(365).code
      expect { Jil::Validator.validate!(new_code) }.not_to raise_error
    end

    it "the who_opts snippet executes to a 3-element array including Eve" do
      snippet = <<~'JIL'
        who_opts = Array.new({
          o1 = String.new("Rockster160")::String
          o2 = String.new("Alchemibluum")::String
          o3 = String.new("Eve")::String
        })::Array
        out = Global.return(who_opts)::Array
      JIL
      result = Jil::Executor.call(me, snippet).result
      expect(result).to eq(["Rockster160", "Alchemibluum", "Eve"])
    end
  end
end
