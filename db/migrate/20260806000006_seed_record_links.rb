class SeedRecordLinks < ActiveRecord::Migration[7.1]
  # Move the pairings out of Jil tasks 361 / 364 / 381 / 370 / 374 and into
  # rows. The list is RecordLinks::Seed, in app code, so it can be asserted on —
  # the test database is rebuilt from schema.rb and never replays migration
  # data, which makes a seed buried in a migration a seed nobody can check.
  #
  # This does NOT disable the Jil tasks. Both systems run side by side until the
  # new path has been watched; retiring them is
  # lib/scripts/retire_jil_link_tasks.rb and it is a deliberate, separate act.
  # Running both is safe because every write on both sides is idempotent — they
  # converge on the same partner row rather than making two.
  #
  # Two of the old rules ran uphill and have no equivalent here: completing a
  # chore no longer writes an event, and adding a list item no longer marks a
  # chore due. The second has a behavioural consequence, handled by
  # lib/scripts/rewrite_mark_due_tasks.rb — run that in the same sitting.
  def up
    unless defined?(RecordLinks::Seed)
      return say("RecordLinks::Seed is gone — skipping")
    end

    owner = User.find_by(id: 1) || User.where.not(chore_household_id: nil).order(:id).first
    return say("no owner to seed links for — skipping") if owner.nil?

    say("planted #{RecordLinks::Seed.plant!(owner)} record links for #{owner.username}")
  end

  def down
    RecordLink.where(note: "migrated from Jil").delete_all
  end
end
