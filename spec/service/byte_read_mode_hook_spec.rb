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

  def decide(tool_name, tool_input, mode: "read")
    env = {
      "BYTE_LOCAL_SECRET"    => "test-secret",
      "BYTE_CONVERSATION_ID" => "999",
      "BYTE_PERMISSION_MODE" => mode,
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

  def bash(cmd) = decide("Bash", { "command" => cmd })

  describe "what it lets through" do
    it "allows the git reads the brief is built from" do
      expect(bash("git -C /Users/zoro/code/ocs-backend worktree list")).to eq("allow")
      expect(bash("git log --all --author=rocco --since=2026-09-02 --format=%h %s")).to eq("allow")
      expect(bash("git -C /x status --porcelain")).to eq("allow")
      expect(bash("git branch -a --merged origin/main")).to eq("allow")
    end

    it "allows a fetch, which moves refs and nothing else" do
      expect(bash("git fetch --prune origin")).to eq("allow")
    end

    it "allows gh for the merged-vs-open question" do
      expect(bash("gh pr list --state all --author @me")).to eq("allow")
    end

    it "allows a pipeline where every stage is a read" do
      expect(bash("git log --oneline | head -20 | sort")).to eq("allow")
    end

    it "allows the discards that write nothing" do
      expect(bash("git status 2>/dev/null")).to eq("allow")
      expect(bash("gh pr list 2>&1 | head -5")).to eq("allow")
    end

    it "allows the file tools" do
      expect(decide("Read", { "file_path" => "/Users/zoro/code/ocs-backend/README.md" })).to eq("allow")
      expect(decide("Grep", { "pattern" => "def foo" })).to eq("allow")
      expect(decide("Glob", { "pattern" => "**/*.rb" })).to eq("allow")
    end
  end

  describe "what it refuses" do
    # The thing the whole mode exists for. Someone may be mid-edit in that
    # worktree right now.
    it "refuses to move a working tree" do
      expect(bash("git checkout main")).to eq("deny")
      expect(bash("git switch rn/feature/dex-errors")).to eq("deny")
      expect(bash("git stash")).to eq("deny")
    end

    # `-C` is normalised away so a read can address another repo; that must not
    # turn into a doorway for the subcommands the mode exists to refuse.
    it "refuses one aimed at another repo with -C just the same" do
      expect(bash("git -C /Users/zoro/code/ocs-backend checkout main")).to eq("deny")
      expect(bash("git -C /x -C /y stash")).to eq("deny")
    end

    # A config value is where an alias would hide, and this never looks inside one.
    it "refuses a command carrying inline config" do
      expect(bash("git -c alias.x=!rm log")).to eq("deny")
    end

    # `git stash list` is a read and `git stash` is not, and a prefix match on
    # the word alone cannot tell them apart.
    it "tells `git stash list` from `git stash`" do
      expect(bash("git stash list")).to eq("allow")
      expect(bash("git stash push -m x")).to eq("deny")
    end

    it "refuses writes and history rewrites" do
      expect(bash("git commit -am wip")).to eq("deny")
      expect(bash("git push origin main")).to eq("deny")
      expect(bash("rm -rf /tmp/x")).to eq("deny")
      expect(decide("Write", { "file_path" => "/tmp/x", "content" => "y" })).to eq("deny")
      expect(decide("Edit", { "file_path" => "/tmp/x" })).to eq("deny")
    end

    # A prefix match only ever looks at the front of the string, so an allowed
    # first token is a doorway for everything chained behind it.
    it "checks every segment, not just the first" do
      expect(bash("git log --oneline && git checkout main")).to eq("deny")
      expect(bash("ls; rm -rf /tmp/x")).to eq("deny")
      expect(bash("git status | xargs rm")).to eq("deny")
    end

    it "refuses a redirect, which is a write however the line starts" do
      expect(bash("git log > /tmp/out.txt")).to eq("deny")
      expect(bash("echo hi >> ~/.zshrc")).to eq("deny")
    end

    it "refuses command substitution, which hides the real command" do
      expect(bash("ls $(git checkout main)")).to eq("deny")
      expect(bash("ls `rm -rf /tmp/x`")).to eq("deny")
    end

    # Both take a program that can open a file for writing, so allowing them
    # would put the guarantee inside an argument parser.
    it "refuses the tools whose arguments are programs" do
      expect(bash("awk '{print $1}' file")).to eq("deny")
      expect(bash("sed -n 1,5p file")).to eq("deny")
      expect(bash("perl -i -pe s/a/b/ file")).to eq("deny")
    end

    it "still refuses a secret it would otherwise be able to read" do
      expect(decide("Read", { "file_path" => "/Users/zoro/code/Portfolio/.env" })).to eq("deny")
      expect(bash("cat ~/.ssh/id_rsa")).to eq("deny")
    end
  end

  # There is nobody in front of this run. A card is a ten-minute stall inside a
  # fifteen-minute window, not a safeguard.
  describe "never asking" do
    it "denies instead of posting a card, with no server to reach" do
      expect(bash("git checkout main")).to eq("deny")
    end

    it "denies a question rather than posting one nobody will answer" do
      expect(decide("AskUserQuestion", { "questions" => [] })).to eq("deny")
    end

    it "denies a plan rather than waiting for approval" do
      expect(decide("ExitPlanMode", { "plan" => "do the thing" })).to eq("deny")
    end

    it "tells the model not to retry or ask" do
      env = {
        "BYTE_LOCAL_SECRET"    => "s",
        "BYTE_CONVERSATION_ID" => "999",
        "BYTE_PERMISSION_MODE" => "read",
        "BYTE_LOCAL_URL"       => "http://127.0.0.1:1",
      }
      envelope = JSON.generate({
        "tool_name"  => "Bash",
        "tool_input" => { "command" => "git checkout main" },
        "cwd"        => "/Users/zoro/code/ocs-backend",
      })
      out, = Open3.capture2(env, "ruby", HOOK, stdin_data: envelope)
      reason = JSON.parse(out).dig("hookSpecificOutput", "permissionDecisionReason")

      expect(reason).to include("do not ask")
      expect(reason).to include("read-only")
    end
  end

  # `ask` mode is exactly as wide as whatever has ever been tapped "always
  # allow". ocs-backend's own `.claude/settings.local.json` allows
  # `Bash(git checkout:*)`, `Bash(git stash:*)`, `Bash(perl -i -pe:*)` and
  # `Bash(rails runner:*)` — every one of which this mode has to refuse in that
  # same directory, or the guarantee is only as good as a file anyone can widen
  # with one tap.
  describe "ignoring the allow lists" do
    it "refuses what this project's own settings allow" do
      expect(bash("git checkout main")).to eq("deny")
      expect(bash("git stash")).to eq("deny")
      expect(bash("perl -i -pe s/a/b/ x")).to eq("deny")
      expect(bash("rails runner 'puts 1'")).to eq("deny")
    end

    it "removed the bare Bash wildcard that made ask mode unbounded" do
      settings = JSON.parse(File.read("/Users/zoro/code/.claude-personal/settings.json"))

      expect(settings.dig("permissions", "allow")).not_to include("Bash")
    end
  end
end
# rubocop:enable RSpec/DescribeClass
