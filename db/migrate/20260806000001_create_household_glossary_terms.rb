class CreateHouseholdGlossaryTerms < ActiveRecord::Migration[7.1]
  # The words this house uses that nobody else would understand. "Muti" is
  # medicine, "boot" is the car's trunk, "the plunge" is one specific trailhead
  # in Alpine, and "puppy" is a particular dog with a name.
  #
  # All of this already existed — as prose, hardcoded in the middle of Buddy's
  # system prompt. That worked but couldn't be edited by the people who actually
  # coin the words: adding one meant a deploy, so in practice they didn't get
  # added, and the companion kept mishearing the same handful of terms.
  #
  # Household-scoped rather than per-user, because a household's vocabulary is
  # the one thing everybody in it shares by definition. Eve saying "muti" and
  # Chelsea saying "muti" mean the same thing, and teaching it twice would be
  # the bug.
  def change
    create_table :household_glossary_terms do |t|
      t.belongs_to :chore_household, index: true
      t.text :term, null: false
      t.text :meaning, null: false
      # Other ways to say the same thing. "puppy" and "the dog" both land on
      # Whisper, and the alias list is what makes that a lookup instead of a
      # guess.
      t.jsonb :aliases, default: [], null: false
      t.integer :kind
      # Anything the meaning alone doesn't carry — most usefully, when a term is
      # a record name that must never be spoken back in prose ("Puppy Up").
      t.text :notes

      t.timestamps
    end

    # One entry per word per house. Case-insensitive because the whole point is
    # that people type these however they feel like typing them.
    add_index :household_glossary_terms,
      "chore_household_id, lower(term)",
      unique: true,
      name:   :index_glossary_terms_on_household_and_lower_term
  end
end
