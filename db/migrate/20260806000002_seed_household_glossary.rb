class SeedHouseholdGlossary < ActiveRecord::Migration[7.1]
  # Plant the starting vocabulary so the companion doesn't get dumber on the
  # deploy that takes those words out of its system prompt.
  #
  # The list itself is Buddy::GlossarySeed, not a constant in here — a seed
  # buried in a migration is one no spec can check, since the test database is
  # rebuilt from schema.rb and never replays migration data. The guard is for
  # the day that module is renamed and someone rebuilds a database from
  # scratch: a missing starter glossary is a small loss, a failed migration
  # chain is not.
  def up
    unless defined?(Buddy::GlossarySeed)
      return say("Buddy::GlossarySeed is gone — skipping the starter glossary")
    end

    household_id = owner_household_id
    return say("no household to seed a glossary for — skipping") if household_id.nil?

    planted = Buddy::GlossarySeed.plant!(ChoreHousehold.find(household_id))
    say("planted #{planted} glossary terms for household #{household_id}")
  end

  def down
    return unless defined?(Buddy::GlossarySeed)

    household_id = owner_household_id
    return if household_id.nil?

    HouseholdGlossaryTerm
      .where(chore_household_id: household_id, term: Buddy::GlossarySeed::TERMS.pluck(:term))
      .delete_all
  end

  private

  # The owner's household. Read off the column rather than through User.me so
  # this still resolves on a database where nobody is flagged as the owner yet.
  def owner_household_id
    select_value(<<~SQL.squish)
      SELECT chore_household_id FROM users
      WHERE chore_household_id IS NOT NULL
      ORDER BY id ASC
      LIMIT 1
    SQL
  end
end
