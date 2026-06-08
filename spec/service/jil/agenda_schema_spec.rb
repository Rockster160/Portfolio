require "rails_helper"

RSpec.describe "Jil Agenda schema entries" do
  it "validates a class-level search call with limit + order" do
    code = <<~'JIL'
      items = Agenda.search("kind:task is:incomplete is:overdue" 25 "ASC")::Array
    JIL
    expect { ::Jil::Validator.validate!(code) }.not_to raise_error
  end

  it "validates Agenda.find returning an Agenda" do
    code = <<~'JIL'
      my_agenda = Agenda.find("Work")::Agenda
    JIL
    expect { ::Jil::Validator.validate!(code) }.not_to raise_error
  end

  it "validates the instance-level items call" do
    code = <<~'JIL'
      my_agenda = Agenda.find("Work")::Agenda
      today_items = my_agenda.items()::Array
    JIL
    expect { ::Jil::Validator.validate!(code) }.not_to raise_error
  end

  it "validates add_task / add_event class methods" do
    code = <<~'JIL'
      task = Agenda.add_task("Work" "Standup" "2026-05-15T09:00")::AgendaItem
      meet = Agenda.add_event("Work" "Demo" "2026-05-15T10:00" "2026-05-15T11:00")::AgendaItem
    JIL
    expect { ::Jil::Validator.validate!(code) }.not_to raise_error
  end

  it "validates AgendaItem#complete called on a hash item" do
    code = <<~'JIL'
      items = Agenda.search("kind:task is:incomplete" 50 "ASC")::Array
      first = items.first()::AgendaItem
      done = first.complete()::Boolean
    JIL
    expect { ::Jil::Validator.validate!(code) }.not_to raise_error
  end

  it "validates AgendaItem getters and predicates" do
    code = <<~'JIL'
      items = Agenda.search("kind:task" 50 "ASC")::Array
      first = items.first()::AgendaItem
      item_name = first.name()::String
      item_color = first.color()::String
      item_start = first.start_at()::Date
      done = first.completed?()::Boolean
      recurring = first.recurring?()::Boolean
      parent = first.agenda()::Hash
    JIL
    expect { ::Jil::Validator.validate!(code) }.not_to raise_error
  end

  it "validates AgendaItem update! + destroy with named-arg content block" do
    code = <<~'JIL'
      items = Agenda.search("kind:task" 50 "ASC")::Array
      target = items.first()::AgendaItem
      updated = target.update!({
        upd_name = AgendaItemData.name("New Name")::AgendaItemData
        upd_color = AgendaItemData.color("#ff0000")::AgendaItemData
      })::AgendaItem
      gone = updated.destroy()::Boolean
    JIL
    expect { ::Jil::Validator.validate!(code) }.not_to raise_error
  end

  describe "end-to-end execution" do
    let(:user) { create(:user) }
    let(:agenda) { create(:agenda, user: user, name: "Work", color: "#aaaaaa") }
    let!(:item) {
      create(:agenda_item, agenda: agenda, kind: :task, name: "Old",
        notes: "old notes", color: "#cccccc", start_at: 1.hour.ago, completed_at: nil)
    }

    it "updates an AgendaItem via the content block syntax" do
      code = <<~JIL
        items = Agenda.search("kind:task is:incomplete" 50 "ASC")::Array
        target = items.first()::AgendaItem
        updated = target.update!({
          upd_name = AgendaItemData.name("Renamed")::AgendaItemData
          upd_notes = AgendaItemData.notes("Fresh notes")::AgendaItemData
          upd_color = AgendaItemData.color("#ff0000")::AgendaItemData
        })::AgendaItem
      JIL
      Jil::Executor.call(user, code)

      item.reload
      expect(item.name).to eq("Renamed")
      expect(item.notes).to eq("Fresh notes")
      expect(item.color).to eq("#ff0000")
    end

    it "updates an Agenda via the content block syntax" do
      code = <<~JIL
        my_agenda = Agenda.find("Work")::Agenda
        renamed = my_agenda.update!({
          upd_name = AgendaData.name("Renamed Work")::AgendaData
          upd_color = AgendaData.color("#00ff00")::AgendaData
        })::Agenda
      JIL
      Jil::Executor.call(user, code)

      agenda.reload
      expect(agenda.name).to eq("Renamed Work")
      expect(agenda.color).to eq("#00ff00")
    end
  end

  describe "add_task defaults" do
    let(:user) { create(:user) }
    let!(:agenda) { create(:agenda, user: user, name: "Inbox") }

    it "defaults to the next top of the hour when start_at is blank" do
      Time.use_zone("America/Denver") {
        travel_to(Time.zone.local(2026, 6, 8, 15, 4, 17)) do
          code = <<~'JIL'
            new_task = Agenda.add_task("Inbox" "Take out trash" "")::AgendaItem
          JIL
          Jil::Executor.call(user, code)

          item = agenda.agenda_items.find_by!(name: "Take out trash")
          expect(item.kind).to eq("task")
          expect(item.end_at).to be_nil
          expect(item.start_at).to eq(Time.zone.local(2026, 6, 8, 16, 0, 0))
        end
      }
    end

    it "honors an explicit start_at timestamp" do
      Time.use_zone("America/Denver") {
        travel_to(Time.zone.local(2026, 6, 8, 15, 4, 17)) do
          code = <<~'JIL'
            new_task = Agenda.add_task("Inbox" "Call mom" "2026-06-09T10:30")::AgendaItem
          JIL
          Jil::Executor.call(user, code)

          item = agenda.agenda_items.find_by!(name: "Call mom")
          expect(item.end_at).to be_nil
          expect(item.start_at).to eq(Time.zone.local(2026, 6, 9, 10, 30, 0))
        end
      }
    end
  end

  it "validates Agenda getters and update! with named-arg content block" do
    code = <<~'JIL'
      my_agenda = Agenda.find("Work")::Agenda
      agenda_id = my_agenda.id()::Numeric
      agenda_color = my_agenda.color()::String
      scheds = my_agenda.schedules()::Array
      renamed = my_agenda.update!({
        upd_name = AgendaData.name("Renamed")::AgendaData
      })::Agenda
    JIL
    expect { ::Jil::Validator.validate!(code) }.not_to raise_error
  end
end
