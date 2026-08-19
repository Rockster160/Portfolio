require "digest"
require "fileutils"

# Linked files live in shared/ on the server and are symlinked into each
# release. They never travel with a deploy, so nothing in git, CI or code
# review can see them — and that invisibility is how production ran on
# `pool: 5` for years while config/database.yml in this repo claimed 22, with
# a comment explaining reasoning that had never applied to production.
#
# These tasks make that drift visible. They read fetch(:linked_files), so
# adding a file to the list in deploy.rb is all it takes — there is nothing
# here to keep in step.
#
# Deliberately no push task. `.env` on a laptop is the development
# environment's, and copying it over production's would be the worst possible
# outcome of a task named "sync". Writes to shared/ stay manual and deliberate.
namespace :sync_linked do
  # Comments and blank lines are stripped before comparing. Both formats here
  # use `#`, and documenting a setting is not drift — without this, adding a
  # comment to database.yml would mark it as differing forever, which is how a
  # drift report turns into noise nobody reads.
  def significant_digest(text)
    lines = text.lines.reject { |line| line.strip.empty? || line.strip.start_with?("#") }
    Digest::SHA256.hexdigest(lines.join)
  end

  desc "Report which linked files differ between this checkout and the server"
  task :check do
    on roles(:app) do
      differing = []

      fetch(:linked_files).each do |file|
        remote = shared_path.join(file)
        local = Pathname.new(file)

        unless test("[ -f #{remote} ]")
          # The deploy itself fails on a missing linked file, so this is worth
          # shouting about rather than reporting as a difference.
          warn "  MISSING on server  #{file}  (the next deploy will fail)"
          next
        end

        unless local.exist?
          info "  server only        #{file}"
          next
        end

        remote_sum = significant_digest(capture(:cat, remote))
        local_sum = significant_digest(local.read)

        if remote_sum == local_sum
          info "  identical          #{file}"
        else
          differing << file
          info "  DIFFERS            #{file}"
        end
      end

      if differing.any?
        info ""
        info "  #{differing.size} file(s) differ in actual settings, not just comments."
        info "  Expected for .env — those are per-environment by design. Less expected"
        info "  for config/database.yml: it reads its password from ENV, so little in"
        info "  it has to be server-specific."
        info "  `cap production sync_linked:pull` to see the server's copy."
      end
    end
  end

  desc "Download the server's linked files into tmp/linked/ for inspection"
  task :pull do
    on roles(:app) do
      fetch(:linked_files).each do |file|
        remote = shared_path.join(file)
        next unless test("[ -f #{remote} ]")

        local = Pathname.new("tmp/linked").join(file)
        FileUtils.mkdir_p(local.dirname)
        download!(remote, local)
        info "  pulled  #{file}  ->  #{local}"
      end

      info ""
      info "  tmp/ is gitignored, so these will not be committed. They hold real"
      info "  production credentials — delete them when you are done reading."
    end
  end
end
