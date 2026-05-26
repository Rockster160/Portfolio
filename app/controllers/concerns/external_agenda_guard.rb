# Shared 403 guard for write actions against externally-managed agendas
# (currently: Google Calendar sync). The sync pipeline writes through the
# model directly and bypasses controllers, so this guard only fires for
# human-initiated requests.
#
# Renders 403 + halts when `agenda` is externally managed; otherwise no-op.
# Callers use `performed?` to short-circuit (Rails sets it after `render`):
#
#   refuse_external_write!(target)
#   return if performed?
module ExternalAgendaGuard
  extend ActiveSupport::Concern

  private

  def refuse_external_write!(agenda)
    return unless agenda&.managed_externally?

    render json: {
      errors: ["Agenda \"#{agenda.name}\" is synced from an external calendar and is read-only."],
    }, status: :forbidden
  end
end
