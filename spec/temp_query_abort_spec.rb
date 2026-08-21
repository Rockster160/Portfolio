require "rails_helper"

RSpec.describe "malformed query" do
  it "savepoint recovery" do
    scope = BankTransaction.query("timestamp>=notadate")
    begin
      BankTransaction.transaction(requires_new: true) { scope.limit(1).pluck(:id) }
    rescue StandardError => e
      puts "RAISED: #{e.class}"
    end
    begin
      puts "AFTER: #{BankAccount.count}"
    rescue StandardError => e
      puts "AFTER RAISED: #{e.class}"
    end
  end
end
