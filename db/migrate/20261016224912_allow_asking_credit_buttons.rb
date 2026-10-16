class AllowAskingCreditButtons < ActiveRecord::Migration[7.1]
  def change
    change_column_null :chore_credit_buttons, :credit_user_id, true
  end
end
