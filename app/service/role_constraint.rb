class RoleConstraint
  def initialize(*roles)
    @roles = roles.map(&:to_sym)
  end

  def matches?(request)
    user = User.find_by(id: request.cookies["current_user_id"])
    return false if user.blank?

    @roles.include? user.role.to_sym
  end
end
