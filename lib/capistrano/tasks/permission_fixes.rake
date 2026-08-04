namespace :deploy do
  desc "Clear bootsnap cache"
  task :clear_bootsnap_cache do
    on roles(:app) do
      # ensure deploy can remove everything under bootsnap
      execute :chmod, "-R u+rwx #{shared_path}/tmp/cache/bootsnap", raise_on_non_zero_exit: false

      # attempt to clear cache without aborting on failure
      begin
        execute :rm, "-rf #{shared_path}/tmp/cache/bootsnap"
      rescue SSHKit::Command::Failed
        info "Skipping bootsnap cache cleanup error"
      end
    end
  end
end
after "deploy:updated", "deploy:clear_bootsnap_cache"

namespace :deploy do
  # Report anything under the deploy root the app can't own. A file owned by
  # someone else is the kind of thing that fails at 3am rather than at deploy
  # time, so it's worth a look on the way past.
  #
  # It REPORTS and never aborts, because by the time it runs there is nothing
  # left to abort: this hangs off `deploy:finished`, after migrations, after
  # the symlink, after Puma has restarted and is already serving the new code.
  # A non-zero exit here rolls nothing back. All it does is fail the workflow
  # and tell everyone a deploy that worked didn't.
  #
  # 2026-08-04 was exactly that. `find` walked shared/tmp/cache/bootsnap while
  # the app it had just restarted was writing compile-cache temp files into it;
  # one vanished between readdir and stat; find exited 1; cap aborted; and Byte
  # announced a failed deploy for a release that had shipped perfectly. Hence
  # both halves of this - `shared/tmp` is pruned because it is pids, sockets
  # and caches whose ownership means nothing and whose contents churn under an
  # already-running app, and the exit code is ignored because a post-deploy
  # audit has no business failing a deploy.
  desc "Report any file under the deploy root not owned by the deploy user"
  task :verify_permissions do
    on roles(:app) do
      execute(
        "find #{fetch(:deploy_to)} -path #{shared_path}/tmp -prune " \
        "-o ! -user deploy -exec ls -ld {} \\;",
        raise_on_non_zero_exit: false,
      )
    end
  end
end
after "deploy:finished", "deploy:verify_permissions"
