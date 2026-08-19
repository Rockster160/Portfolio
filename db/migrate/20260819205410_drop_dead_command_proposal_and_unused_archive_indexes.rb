class DropDeadCommandProposalAndUnusedArchiveIndexes < ActiveRecord::Migration[7.1]
  # Two unrelated reclaims, both measured against production rather than
  # guessed at. ~557 MB total on a box with 4 GB of RAM and 512 MB of
  # shared_buffers, so this is cache the rest of the database gets back.
  #
  # 1. execution_archives' user_id and task_id indexes: 473 MB between them and
  #    ZERO scans since the stats were last reset in May 2025. Nothing queries
  #    the archive by user or task — ExecutionArchive is written by
  #    ExecutionArchiveWorker and read back by primary key. There is no foreign
  #    key on either column and no has_many on User, so CleanVisitorsWorker's
  #    ownership probe never touches this table either. If a future feature
  #    needs to read archives by user, add the index back then; carrying it for
  #    a year on the chance is what cost the 473 MB.
  #
  # 2. The command_proposal_* tables: installed by a gem in 2021, the gem is
  #    gone from the Gemfile, there is no model or reference anywhere in app/
  #    or lib/, and all three tables hold zero rows. command_proposal_iterations
  #    is still 84 MB of empty pages — mass-deleted long ago and never
  #    truncated (it has no autovacuum record at all).
  def up
    remove_index :execution_archives, name: "index_execution_archives_on_user_id_and_started_at"
    remove_index :execution_archives, name: "index_execution_archives_on_task_id_and_started_at"

    drop_table :command_proposal_comments
    drop_table :command_proposal_iterations
    drop_table :command_proposal_tasks
  end

  def down
    create_table(:command_proposal_tasks, id: :serial) { |t|
      t.text(:name)
      t.text(:friendly_id)
      t.text(:description)
      t.integer(:session_type, default: 0)
      t.datetime(:last_executed_at, precision: nil)
      t.timestamps(precision: nil)
    }

    create_table(:command_proposal_iterations, id: :serial) { |t|
      t.integer(:task_id)
      t.text(:args)
      t.text(:code)
      t.text(:result)
      t.integer(:status, default: 0)
      t.integer(:requester_id)
      t.integer(:approver_id)
      t.datetime(:approved_at, precision: nil)
      t.datetime(:started_at, precision: nil)
      t.datetime(:completed_at, precision: nil)
      t.datetime(:stopped_at, precision: nil)
      t.timestamps(precision: nil)
      t.index(:task_id, name: "index_command_proposal_iterations_on_task_id")
    }

    create_table(:command_proposal_comments, id: :serial) { |t|
      t.integer(:iteration_id)
      t.integer(:line_number)
      t.integer(:author_id)
      t.text(:body)
      t.timestamps(precision: nil)
      t.index(:iteration_id, name: "index_command_proposal_comments_on_iteration_id")
    }

    add_index(
      :execution_archives, [:user_id, :started_at],
      order: { started_at: :desc },
      name:  "index_execution_archives_on_user_id_and_started_at"
    )
    add_index(
      :execution_archives, [:task_id, :started_at],
      order: { started_at: :desc },
      name:  "index_execution_archives_on_task_id_and_started_at"
    )
  end
end
