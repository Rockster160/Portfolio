# `/audit [note]`: a Feature Builder handed a brief instead of a feature. It
# reads the recent Buddy traffic, deploys and errors the way the nightly audit
# does (ByteDailyAudit), and then, unlike that report-only run, asks what it
# needs, fixes what it found and opens a PR, or closes itself when nothing
# called for a change.
#
# The window opens a little before the last `/audit` did, so what that run was
# still in the middle of reading is read again, and falls back to the last day
# when there wasn't one.
module FeatureBuilder
  module Audit
    module_function

    USAGE = "usage: `/audit [what to look at]`".freeze

    # Read again from the last audit, so its last stretch is seen once more by a
    # session that can tell whether what that one did took.
    OVERLAP = 1.hour
    # With no earlier audit to start from.
    DEFAULT_SPAN = 24.hours
    # However long ago the last one was, a week is as much as one run reads.
    LONGEST = 7.days

    # `note` is what the person wants looked at, and may be blank. Returns the
    # request as the person's own message, the way `/feature` does.
    def start!(user:, conversation:, note:, typed: nil, local_id: nil, attachment_signed_ids: [])
      note = note.to_s.strip
      now = Time.current
      span = window(user, now: now)
      posted = nil
      FeatureBuilder.launch!(
        user:                  user,
        conversation:          conversation,
        request:               brief(user, span, note),
        title:                 (title(span) if note.empty?),
        title_from:            note,
        kind:                  :audit,
        attachment_signed_ids: attachment_signed_ids,
      ) { |build|
        said = typed.presence || ["/audit", note.presence].compact.join(" ")
        posted = FeatureBuilder.post_request!(build, conversation, said, { local_id: local_id }.compact)
      }
      posted
    end

    def window(user, now: Time.current)
      last = FeatureBuild.kind_audit.where(user: user, created_at: ...now).maximum(:created_at)
      from = last ? last - OVERLAP : now - DEFAULT_SPAN
      from = [from, now - LONGEST].max
      from.in_time_zone(user.timezone)..now.in_time_zone(user.timezone)
    end

    # Named for its window when it has no note. With one it's named for the
    # note as it starts, the way any build is (FeatureBuilder::Title), under
    # this prefix.
    PREFIX = "Audit: ".freeze

    def title(span)
      "Audit of the last #{ByteDailyAudit.span_length(span)}"
    end

    def brief(user, span, note)
      focus = (
        if note.present?
          "You were asked to look at this, and it comes first: **#{note}**\n\n" \
            "Find where it happened in the window and fix it. Then look over the rest of the window " \
            "too, and fix anything else that plainly went wrong."
        else
          "No particular complaint this time: read the window and judge for yourself what didn't " \
            "work as it should, or could plainly work better, and fix it."
        end
      )
      <<~TXT
        Audit the recent traffic and fix what you find.

        Review the #{ByteDailyAudit.span_length(span)} from **#{ByteDailyAudit.stamp(span.first)}** to **#{ByteDailyAudit.stamp(span.last)}** (America/Denver): every Buddy thread's messages, the deploys that went out, and the errors the app reported. It opens a little before the last `/audit` did, so its last stretch overlaps that run on purpose: check whether what it changed actually took rather than finding it again.

        #{focus}

        HOW THIS RUN WORKS
        You are a Feature Builder like any other: ask what you need (numbered, all at once), post the ticket with `builder-pr plan`, build, test and open one PR. The ticket's **What and why** is the list of problems you found, each citing its message ids, and what you're changing for each one. The PR body's Summary carries the same list.
        - Only fix what the data shows went wrong or plainly could be better. Each fix cites the messages, deploys or error rows behind it.
        - Something already fixed by a later deploy, whose traffic since shows it took, needs nothing: leave it out.
        - Something you can't fix in code (a production record to correct, a Jil task to change) goes in a production script, or under **Before deploying** when it's a setting.
        - Something you found but would be guessing at the fix for is a question, not a change.
        - When nothing in the window calls for a change, close the build with `builder-pr close --reason "..."`, saying in a sentence or two what you read and that it held up.
        - The **Daily Audit** thread holds the nightly read-only reports. Read the ones that overlap this window before calling anything new: a problem one of them raised may already be fixed, or be exactly the thing worth fixing.

        HOW TO TALK
        Every message you end a turn with reaches the owner's phone as a text. Write it like one: a few short lines to take in at a glance, the answer first, no headings, no debrief. Questions are numbered so each can be answered by number. The detail belongs in the ticket and the PR, not in the messages.

        WHERE THE DAY IS
        #{ByteDailyAudit.data_map}

        **Notes left for the audit.** Anyone can type "Note: ..." in a Buddy thread, and it's filed for the audit instead of being answered. Each one points straight at a problem, usually the companion message above it:

        #{Buddy::AuditNotes.block(span, user.timezone)}

        **Errors reported in the window**, grouped, most repeated first:

        #{ByteDailyAudit.errors_block(user, span)}

        #{ByteDailyAudit.standing_rules}
      TXT
    end
  end
end
