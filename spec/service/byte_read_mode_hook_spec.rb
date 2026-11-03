require "json"
require "open3"

# ByteStandupPrep promises a session that reads a repo somebody else may be
# working in and changes nothing. Nothing in THIS repo enforces that — it is one
# `permission_mode` string, and the enforcement is a hook on the Mac. So the
# guarantee is tested where it's relied on, by running the real script as a
# subprocess with a real envelope on stdin.
#
# It lives here rather than beside the hook because ~/code/Byte has no suite,
# and skips rather than fails anywhere the hook isn't on disk — the file is
# outside this repo and will not exist on CI or on another machine.
HOOK = "/Users/zoro/code/Byte/hooks/pretooluse_byte.rb".freeze

# rubocop:disable RSpec/DescribeClass -- the subject is a script in another repo
RSpec.describe "pretooluse_byte.rb read mode" do
  before { skip("hook not present on this machine") unless File.exist?(HOOK) }

  # No server is listening on BYTE_LOCAL_URL, so a decision that tried to post
  # a card for somebody to tap would have nowhere to go.
  def decide(tool_name, tool_input)
    env = {
      "BYTE_LOCAL_SECRET"    => "test-secret",
      "BYTE_CONVERSATION_ID" => "999",
      "BYTE_PERMISSION_MODE" => "read",
      "BYTE_LOCAL_URL"       => "http://127.0.0.1:1",
    }
    envelope = JSON.generate({
      "session_id" => "s",
      "tool_name"  => tool_name,
      "tool_input" => tool_input,
      "cwd"        => "/Users/zoro/code/ocs-backend",
    })
    out, = Open3.capture2(env, "ruby", HOOK, stdin_data: envelope)
    JSON.parse(out).dig("hookSpecificOutput", "permissionDecision")
  end

  # Each decision is its own ruby process, so they run side by side. A bare
  # string is a Bash command; a pair is [tool_name, tool_input].
  def decisions(calls)
    calls.each_slice(12).flat_map { |slice|
      slice.map { |call|
        tool, input = call.is_a?(String) ? ["Bash", { "command" => call }] : call
        Thread.new { [call, decide(tool, input)] }
      }.map(&:value)
    }.to_h
  end

  it "allows reads, pipelines of reads, read-only loops and scratch files", :aggregate_failures do
    calls = [
      # The git reads the brief is built from, and a fetch, which moves refs
      # and nothing else.
      "git -C /Users/zoro/code/ocs-backend worktree list",
      "git log --all --author=rocco --since=2026-09-02 --format=%h %s",
      "git -C /x status --porcelain",
      "git branch -a --merged origin/main",
      "git fetch --prune origin",
      "gh pr list --state all --author @me",
      # `git stash list` is a read and `git stash` is not, and a prefix match on
      # the word alone cannot tell them apart.
      "git stash list",
      "git log --oneline | head -20 | sort",
      "git status 2>/dev/null",
      "gh pr list 2>&1 | head -5",
      # A `>` inside the SQL is a comparison, not a redirect.
      %(bash .claude/prod-query.sh "COPY (SELECT id FROM byte_messages WHERE created_at > now() - interval '1 day'; ) TO STDOUT"),
      # Splitting on `;` turns the loop keywords into segments of their own.
      "for id in 5010 5015; do echo \"== $id\"; bash .claude/prod-query.sh \"COPY (SELECT body FROM byte_messages WHERE id=$id) TO STDOUT\"; done",
      "sed -n '930,1010p' app/service/buddy/context.rb",
      "awk -F',' '{print $4}' /tmp/lt.csv | sort | uniq -c",
      "TZ=America/Denver date -r 1788451191 '+%Y-%m-%d %H:%M'",
      # A report accumulates, so a scratch root takes writes.
      "bash .claude/prod-query.sh \"COPY (SELECT 1) TO STDOUT\" > /tmp/lt.csv",
      ["Write", { "file_path" => "/tmp/lt.csv", "content" => "x" }],
      ["Write", { "file_path" => "/private/tmp/x/y.csv", "content" => "x" }],
      ["Read", { "file_path" => "/Users/zoro/code/ocs-backend/README.md" }],
      ["Grep", { "pattern" => "def foo" }],
      ["Glob", { "pattern" => "**/*.rb" }],
    ]

    decisions(calls).each { |call, decision| expect(decision).to eq("allow"), "refused: #{call.inspect}" }
  end

  it "refuses anything that moves a tree, writes, or hides what it runs, without asking", :aggregate_failures do
    calls = [
      # The thing the whole mode exists for. Someone may be mid-edit in that
      # worktree right now.
      "git checkout main",
      "git switch rn/feature/dex-errors",
      "git stash",
      "git stash push -m x",
      # `-C` is normalised away so a read can address another repo; that must
      # not turn into a doorway for the subcommands the mode exists to refuse.
      "git -C /Users/zoro/code/ocs-backend checkout main",
      "git -C /x -C /y stash",
      # A config value is where an alias would hide.
      "git -c alias.x=!rm log",
      "git commit -am wip",
      "git push origin main",
      "rm -rf /tmp/x",
      # Every segment is checked, not just the first.
      "git log --oneline && git checkout main",
      "ls; rm -rf /tmp/x",
      "git status | xargs rm",
      # Redirects that land outside a scratch root.
      "git log > ~/notes.txt",
      "echo hi >> ~/.zshrc",
      "git log > out.txt",
      # Command substitution hides the real command.
      "ls $(git checkout main)",
      "ls `rm -rf /tmp/x`",
      "cat <(git stash)",
      # The write forms of the tools whose arguments are programs; a `>` inside
      # an awk program is inside quotes and invisible to the scan.
      "sed -i '' 's/a/b/' file",
      "sed -i.bak s/a/b/ file",
      "awk '{print > \"/Users/zoro/.zshrc\"}' file",
      "perl -pe s/a/b/ file",
      # An unclosed quote means the scan has lost track of what is shell.
      "grep 'unterminated /tmp/x",
      "for f in a b; do rm $f; done",
      "if true; then git checkout main; fi",
      "cat ~/.ssh/id_rsa",
      # ocs-backend's own settings allow these in `ask` mode; read mode ignores
      # the allow lists.
      "perl -i -pe s/a/b/ x",
      "rails runner 'puts 1'",
      ["Write", { "file_path" => "/Users/zoro/code/Portfolio/app/x.rb", "content" => "x" }],
      ["Edit", { "file_path" => "/Users/zoro/code/Portfolio/Gemfile" }],
      ["Write", { "file_path" => "/Users/zoro/code/ocs-backend/x.rb", "content" => "y" }],
      ["Edit", { "file_path" => "/Users/zoro/code/ocs-backend/x.rb" }],
      ["Read", { "file_path" => "/Users/zoro/code/Portfolio/.env" }],
      # There is nobody in front of this run, so a question or a plan is denied
      # rather than left waiting.
      ["AskUserQuestion", { "questions" => [] }],
      ["ExitPlanMode", { "plan" => "do the thing" }],
    ]

    decisions(calls).each { |call, decision| expect(decision).to eq("deny"), "allowed: #{call.inspect}" }
  end
end
# rubocop:enable RSpec/DescribeClass
