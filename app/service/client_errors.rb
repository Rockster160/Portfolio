module ClientErrors
  module_function

  SLACK_CHANNEL = "#portfolio".freeze

  # Ids in a path - a record number, a uuid, a long hex token - so every list's
  # page is one place rather than one per list.
  ID_SEGMENT = %r{/(?:\d+|[0-9a-f]{8}-[0-9a-f-]{27,}|[0-9a-f]{16,})(?=/|\z)}i

  # Recorded first, so the alert can link to the row and the row's history can
  # say whether this one is worth announcing at all - the same order every other
  # funnel keeps.
  def report(user:, message:, name:, stack:, page:, build: nil, extra: {})
    section = "js:#{page_for(page)}"
    row = ErrorReport.record!(
      section:     section,
      error_class: name.first(100).presence || "Error",
      message:     message.presence || "(no message)",
      backtrace:   stack.lines.first(ErrorReport::BACKTRACE_FRAMES).join.presence,
      user:        user,
      extra:       extra,
      layer:       :frontend,
      tag:         :browser,
      release:     build.to_s.first(20).presence,
    )
    repeat = (row ? row.announcement : { reason: :new })
    return row if repeat.nil?

    body = [
      "Browser error on `#{section}`: *#{name.presence || "Error"}*\n#{message.truncate(500)}",
      ErrorReport.repeat_note(repeat),
      SlackNotifier.trailer(user, row),
    ].compact_blank.join("\n")
    sent = SlackNotifier.deliver(body, SLACK_CHANNEL, "Portfolio-Bot", ":blackmage:", [])
    row&.announced!(sent) if sent
    row
  end

  def page_for(page)
    path = page.to_s.split(/[?#]/).first.to_s.first(200)
    path = "/#{path}" unless path.start_with?("/")
    path.gsub(ID_SEGMENT, "/:id")
  end
end
