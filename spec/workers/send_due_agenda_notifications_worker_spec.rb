require "rails_helper"

RSpec.describe SendDueAgendaNotificationsWorker do
  let(:owner)  { create(:user) }
  let(:agenda) { create(:agenda, user: owner) }

  def stub_push
    allow(WebPushNotifications).to receive(:send_to)
  end

  describe "task / event push notifications" do
    it "notifies the owner for a just-due task and marks notified_at" do
      stub_push
      item = create(:agenda_item, agenda: agenda, kind: :task, name: "Walk dog",
        start_at: 1.minute.ago)
      described_class.new.perform
      expect(WebPushNotifications).to have_received(:send_to).with(
        owner, hash_including(title: "Walk dog"), channel: :agenda,
      )
      expect(item.reload.notified_at).to be_present
    end

    it "skips items the user completed already" do
      stub_push
      create(:agenda_item, agenda: agenda, kind: :task, start_at: 1.minute.ago,
        completed_at: Time.current)
      described_class.new.perform
      expect(WebPushNotifications).not_to have_received(:send_to)
    end

    it "skips items already marked notified_at (broadcast attempt only happens once)" do
      stub_push
      item = create(:agenda_item, agenda: agenda, kind: :task, start_at: 1.minute.ago)
      described_class.new.perform
      described_class.new.perform
      expect(WebPushNotifications).to have_received(:send_to).once
      expect(item.reload.notified_at).to be_present
    end

    it "ignores items beyond the catchup window" do
      stub_push
      create(:agenda_item, agenda: agenda, kind: :task,
        start_at: (described_class::CATCHUP_WINDOW + 5.minutes).ago)
      described_class.new.perform
      expect(WebPushNotifications).not_to have_received(:send_to)
    end

    it "marks notified_at even when no users were eligible (no retroactive pings)" do
      stub_push
      # Owner mutes all tasks for this agenda.
      AgendaNotificationSetting.create!(user: owner, agenda: agenda,
        notify_task_oneoff: false, notify_task_recurring: false)
      item = create(:agenda_item, agenda: agenda, kind: :task, start_at: 1.minute.ago)
      described_class.new.perform

      expect(WebPushNotifications).not_to have_received(:send_to)
      expect(item.reload.notified_at).to be_present

      # Later, the user changes their mind and turns task notifications back on.
      # The item should STILL be skipped — broadcast was already attempted.
      AgendaNotificationSetting.find_by(user: owner, agenda: agenda).update!(
        notify_task_oneoff: true, notify_task_recurring: true,
      )
      described_class.new.perform
      expect(WebPushNotifications).not_to have_received(:send_to)
    end
  end

  describe "shared agendas (multi-recipient)" do
    let(:other) { create(:user, phone: "5559876543") }

    it "notifies every accessible user, respecting their individual settings" do
      stub_push
      AgendaShare.create!(agenda: agenda, user: other, permission: :viewer)
      # `other` mutes tasks on this agenda.
      AgendaNotificationSetting.create!(user: other, agenda: agenda,
        notify_task_oneoff: false, notify_task_recurring: false)
      item = create(:agenda_item, agenda: agenda, kind: :task, name: "Mine",
        start_at: 1.minute.ago)
      described_class.new.perform

      expect(WebPushNotifications).to have_received(:send_to).with(owner, anything, channel: :agenda)
      expect(WebPushNotifications).not_to have_received(:send_to).with(other, anything, channel: :agenda)
      expect(item.reload.notified_at).to be_present
    end
  end

  describe "recurrence axis" do
    it "skips a recurring event for a user who only wants one-off events" do
      stub_push
      AgendaNotificationSetting.create!(user: owner, agenda: agenda,
        notify_event_recurring: false)
      sched = create(:agenda_schedule, agenda: agenda, kind: :event,
        start_time: "09:00", duration_minutes: 30,
        recurrence: { "freq" => "daily" }, starts_on: Date.current)
      _materialized = sched.agenda_items.create!(
        agenda: agenda, kind: :event, name: "Standup",
        start_at: 1.minute.ago, end_at: 1.hour.from_now,
      )
      described_class.new.perform
      expect(WebPushNotifications).not_to have_received(:send_to)
    end

    it "notifies for a one-off event under the same setting" do
      stub_push
      AgendaNotificationSetting.create!(user: owner, agenda: agenda,
        notify_event_recurring: false)
      create(:agenda_item, agenda: agenda, kind: :event, name: "Lunch",
        start_at: 1.minute.ago, end_at: 1.hour.from_now)
      described_class.new.perform
      expect(WebPushNotifications).to have_received(:send_to).once
    end
  end

  describe "triggers" do
    it "are skipped by default (notify_trigger=false out of the box)" do
      stub_push
      create(:agenda_item, agenda: agenda, kind: :trigger, name: "GoodMorning",
        trigger_expression: "goodMorning", start_at: 1.minute.ago)
      described_class.new.perform
      expect(WebPushNotifications).not_to have_received(:send_to)
    end

    it "notify when the user has explicitly opted in" do
      stub_push
      AgendaNotificationSetting.create!(user: owner, agenda: agenda,
        notify_trigger_oneoff: true)
      create(:agenda_item, agenda: agenda, kind: :trigger, name: "GoodMorning",
        trigger_expression: "goodMorning", start_at: 1.minute.ago)
      described_class.new.perform
      expect(WebPushNotifications).to have_received(:send_to).once
    end
  end

  describe "rescheduling re-arms the notification" do
    it "clears notified_at when start_at is moved into the future" do
      item = create(:agenda_item, agenda: agenda, kind: :task,
        start_at: 1.minute.ago, notified_at: Time.current)
      item.update!(start_at: 1.hour.from_now)
      expect(item.reload.notified_at).to be_nil
    end

    it "leaves notified_at alone when start_at is moved into the past (no retroactive pings)" do
      item = create(:agenda_item, agenda: agenda, kind: :task,
        start_at: Time.current, notified_at: Time.current)
      item.update!(start_at: 1.day.ago)
      expect(item.reload.notified_at).to be_present
    end

    it "fires a fresh push after the reschedule, at the new start_at" do
      stub_push
      item = create(:agenda_item, agenda: agenda, kind: :task, name: "Walk dog",
        start_at: 2.minutes.ago)
      # First run: fires + marks notified.
      described_class.new.perform
      expect(item.reload.notified_at).to be_present
      # User pushes the task forward to a new "just-due" moment. (Use a tiny
      # window so the worker still considers it due on the next pass.)
      item.update!(start_at: 1.minute.from_now)
      expect(item.reload.notified_at).to be_nil
      # Time advances past the new start_at — worker fires again.
      Timecop.travel(2.minutes.from_now) do
        described_class.new.perform
        expect(WebPushNotifications).to have_received(:send_to).twice
      end
    end
  end

  describe "phantom materialization" do
    it "materializes today's just-due phantom of a recurring task and notifies" do
      stub_push
      # 09:01 MDT (the user's zone) = 15:01 UTC. The schedule's 09:00 start
      # is in MDT, so we have to freeze in UTC to cross that local boundary.
      Timecop.freeze(Time.utc(2026, 5, 15, 15, 1, 0)) do
        sched = create(:agenda_schedule, agenda: agenda, kind: :task,
          name: "Brush teeth", start_time: "09:00",
          recurrence: { "freq" => "daily" }, starts_on: Date.current - 1)
        expect(sched.agenda_items.count).to eq(0)

        described_class.new.perform

        # Materialized a row for today + notified the owner.
        expect(sched.agenda_items.count).to eq(1)
        expect(WebPushNotifications).to have_received(:send_to).with(
          owner, hash_including(title: "Brush teeth"), channel: :agenda,
        )
      end
    end
  end
end
