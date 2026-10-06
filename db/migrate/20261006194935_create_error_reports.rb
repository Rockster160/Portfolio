# One row per failure reported anywhere in the app, so the day's errors are a
# record rather than a Slack channel nobody scrolls back through. The Daily
# Audit reads production over `prod-query.sh`, which is what puts them in front
# of the machine that can do something about them.
class CreateErrorReports < ActiveRecord::Migration[7.1]
  def change
    create_table :error_reports do |t|
      # Where it was reported from: a Buddy section name, or the file and line
      # the Slack ping came out of.
      t.text :section, null: false
      t.text :error_class
      t.text :message
      t.text :backtrace
      # The same failure twice has the same fingerprint, which is what makes
      # "this happened 40 times" one line in a report instead of forty.
      t.text :fingerprint, null: false
      # The channel it was announced in, or null when nothing was sent - a
      # failure recorded and never announced is the one worth knowing about.
      t.text :channel
      t.bigint :user_id
      t.jsonb :extra, null: false, default: {}

      t.timestamps
    end

    add_index :error_reports, :created_at
    add_index :error_reports, [:fingerprint, :created_at]
    add_index :error_reports, :user_id
  end
end
