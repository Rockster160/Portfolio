# Runs a block once the open database transaction commits, or straight away when
# there isn't one. For telling the outside world about a change: a broadcast
# sent from inside a transaction reaches a client that re-reads before the
# commit, so it fetches the old state and paints it as current. Dropped if the
# transaction rolls back - nothing changed, so there's nothing to tell.
module AfterCommit
  module_function

  def run(&block)
    connection = ActiveRecord::Base.connection
    # Not joinable is the outermost level: no transaction at all, or the one a
    # test wraps around each example, which never commits.
    return yield unless connection.current_transaction.joinable?

    connection.add_transaction_record(Callback.new(block))
  end

  # The shape a transaction asks of a record it will report back to.
  class Callback
    def initialize(block)
      @block = block
    end

    def before_committed!; end

    # Once: a commit can report a record more than once on its way out, and
    # only one of those reports carries `should_run_callbacks`.
    def committed!(should_run_callbacks: true, **)
      return if @ran || !should_run_callbacks

      @ran = true
      @block.call
    end

    def rolledback!(*, **); end

    def trigger_transactional_callbacks?
      true
    end
  end
end
