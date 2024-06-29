class AddUserToEmail < ActiveRecord::Migration[7.1]
  def change
    add_reference :emails, :user

    reversible do |m|
      m.up do
        ::Email.update_all(user_id: 1)
      end
    end
  end
end
