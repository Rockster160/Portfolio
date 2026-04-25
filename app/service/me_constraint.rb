class MeConstraint
  def matches?(request)
    user = User.find_by(id: request.cookies["current_user_id"])
    !!user&.me?
  end
end
