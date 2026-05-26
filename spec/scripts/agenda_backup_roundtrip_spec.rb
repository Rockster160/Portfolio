require "rails_helper"

# Round-trip verification of the export/restore pair. These scripts are
# rollback tools for the GCal sync deploy; they need to be byte-for-byte
# safe across populated → mutated → restored cycles.
RSpec.describe "lib/scripts/agenda_backup_{export,restore}.rb" do # rubocop:disable RSpec/DescribeClass
  let(:user) { create(:user, phone: "5550000001") }
  let(:other_user) { create(:user, phone: "5550000002") }

  # Drive FileStorage in :local mode for the spec — uses tmp/file_storage
  # instead of hitting S3. Restored to the previous setting after each
  # example so we don't leak state into other specs.
  around do |example|
    previous_mode = FileStorage.instance_variable_get(:@mode)
    FileStorage.mode = :local
    example.run
  ensure
    FileStorage.instance_variable_set(:@mode, previous_mode)
    FileUtils.rm_rf(FileStorage::TMP_DIR)
  end

  # Build a state that exercises every table + every association.
  def seed_state!
    a1 = create(:agenda, user: user, name: "Personal", color: "#ff0000")
    a2 = create(:agenda, user: user, name: "Work", color: "#00ff00")

    sched = create(
      :agenda_schedule, agenda: a1, name: "Standup", kind: :event,
      start_time: "09:00", duration_minutes: 30, starts_on: Date.current,
      recurrence: { "freq" => "weekdays", "by_day" => %w[mon tue wed] }
    )

    create(
      :agenda_item, agenda: a1, agenda_schedule: sched, kind: :event,
      name: "Standup occurrence", start_at: 1.hour.from_now,
      end_at: 1.hour.from_now + 30.minutes, detached_at: Time.current,
      original_start_at: Time.current
    )
    create(:agenda_item, agenda: a2, kind: :task, name: "Buy milk", start_at: 1.day.from_now)

    AgendaShare.create!(agenda: a1, user: other_user, permission: :editor)
    AgendaNotificationSetting.create!(
      user: user, agenda: a1,
      notify_task_oneoff:    true,
      notify_event_oneoff:   false,
      notify_event_recurring: true
    )
  end

  def snapshot_state
    {
      agendas:          Agenda.unscoped.order(:id).map(&:attributes),
      agenda_schedules: AgendaSchedule.unscoped.order(:id).map(&:attributes),
      agenda_items:     AgendaItem.unscoped.order(:id).map(&:attributes),
      agenda_shares:    AgendaShare.unscoped.order(:id).map(&:attributes),
      agenda_settings:  AgendaNotificationSetting.unscoped.order(:id).map(&:attributes),
    }
  end

  # `load` re-defines top-level constants in the scripts; silence the
  # spec-only warnings so the suite output stays clean.
  def run_script(filename)
    original_verbose = $VERBOSE
    $VERBOSE = nil
    load Rails.root.join("lib/scripts/#{filename}").to_s
  ensure
    $VERBOSE = original_verbose
  end

  # The export script picks its filename based on Time.current — spy on
  # FileStorage.upload to capture exactly what key was written so the
  # restore step can look it up.
  def export_and_capture_filename
    captured = nil
    allow(FileStorage).to(receive(:upload).and_wrap_original { |original, *args, **kwargs|
      captured = kwargs[:filename]
      original.call(*args, **kwargs)
    })
    silence_stream($stdout) { run_script("agenda_backup_export.rb") }
    captured
  end

  # Force-eval both let-blocks; the spec body relies on the users existing.
  before {
    user
    other_user
  }

  it "produces a snapshot the restore script can use to recreate the exact prior state" do
    seed_state!
    original = snapshot_state

    filename = export_and_capture_filename
    expect(filename).to be_present
    expect(FileStorage.exists?(filename)).to be(true)

    # Mutate live state: delete some rows, edit others, add new ones.
    Agenda.first.update!(name: "RENAMED")
    AgendaItem.first.destroy
    create(:agenda_item, agenda: Agenda.last, kind: :task, name: "Extra", start_at: 1.hour.from_now)
    AgendaShare.delete_all
    expect(snapshot_state).not_to eq(original)

    ENV["BACKUP_FILE"] = filename
    silence_stream($stdout) { run_script("agenda_backup_restore.rb") }
    ENV.delete("BACKUP_FILE")

    expect(snapshot_state).to eq(original)
  end

  it "is idempotent — running restore twice yields the same state" do
    seed_state!
    filename = export_and_capture_filename
    ENV["BACKUP_FILE"] = filename

    silence_stream($stdout) { run_script("agenda_backup_restore.rb") }
    once = snapshot_state
    silence_stream($stdout) { run_script("agenda_backup_restore.rb") }
    twice = snapshot_state

    expect(twice).to eq(once)
    ENV.delete("BACKUP_FILE")
  end

  it "tolerates additive schema drift between snapshot and restore" do
    seed_state!
    filename = export_and_capture_filename

    # Simulate "snapshot has a column the live schema no longer has" by
    # injecting a fake key into every row of every table and re-uploading.
    manifest = JSON.parse(FileStorage.download(filename))
    manifest["tables"].each_value { |t|
      t["rows"].each { |r| r["future_column_we_removed"] = "ignore-me" }
    }
    FileStorage.upload(JSON.dump(manifest), filename: filename)

    Agenda.first.update!(name: "RENAMED")
    ENV["BACKUP_FILE"] = filename
    expect { silence_stream($stdout) { run_script("agenda_backup_restore.rb") } }.not_to raise_error
    ENV.delete("BACKUP_FILE")

    expect(Agenda.first.name).not_to eq("RENAMED") # restore succeeded
  end

  it "raises when BACKUP_FILE is not set" do
    ENV.delete("BACKUP_FILE")
    expect { silence_stream($stdout) { run_script("agenda_backup_restore.rb") } }
      .to raise_error(RuntimeError, /BACKUP_FILE is required/)
  end

  it "raises when BACKUP_FILE points to a missing snapshot" do
    ENV["BACKUP_FILE"] = "agenda_backups/does_not_exist.json"
    expect { silence_stream($stdout) { run_script("agenda_backup_restore.rb") } }
      .to raise_error(RuntimeError, /not found in storage/)
    ENV.delete("BACKUP_FILE")
  end

  # Helper — silence script's stdout chatter so the spec output stays clean.
  def silence_stream(stream)
    old = stream.dup
    stream.reopen(File::NULL)
    yield
  ensure
    stream.reopen(old)
    old.close
  end
end
