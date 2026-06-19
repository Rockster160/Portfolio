class AddClientMutationIdToChoreCompletions < ActiveRecord::Migration[7.1]
  def change
    add_column :chore_completions, :client_mutation_id, :string

    add_index :chore_completions,
      [:user_id, :client_mutation_id],
      unique: true,
      where:  "client_mutation_id IS NOT NULL",
      name:   :index_chore_completions_on_user_and_mutation_id
  end
end
