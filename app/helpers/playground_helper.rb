module PlaygroundHelper
  def playground_open_url(project)
    return unless project.openable?
    return public_send(:"#{project.path}_url", subdomain: project.subdomain) if project.subdomain.present?

    project.entry_path
  end

  # The card's tag for a project you need more than a visit to open.
  def playground_access_tag(project)
    case project.access
    when :account then tag.span("Account", class: "project-tag")
    when :admin then tag.span("Admin", class: "project-tag tag-admin")
    when :owner then tag.span("Private", class: "project-tag tag-private")
    end
  end

  # Why this visitor can't open it, or nil when they can (or when there's
  # nothing to open).
  def playground_locked_reason(project)
    return if !project.openable? || project.open_to?(current_user)

    case project.access
    when :account
      return "Finish creating your account to use this tool" if current_user&.guest?

      "You must have an account to use this tool"
    when :admin then "Only admins can use this tool"
    when :owner then "This tool is private"
    end
  end
end
