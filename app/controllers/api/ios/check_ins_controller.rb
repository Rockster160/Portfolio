# What "open a check-in" lands on: the questions waiting for an answer, oldest
# first, and the mood check-in in the Buddy thread when there are none.
class Api::Ios::CheckInsController < Api::Ios::BaseController
  def index
    prompts = current_user.prompts.unanswered.order(:created_at)
    conversation = ByteConversation.primary_for(current_user)
    render json: {
      prompts:  prompts.map { |prompt|
        {
          id:    prompt.id,
          title: prompt.question,
          url:   absolute("/prompts/#{prompt.id}"),
        }.merge(AppDevices::NotificationActions.for_prompt(prompt))
      },
      mood_url: byte_url(conversation ? "/?conversation_id=#{conversation.id}&check_in=1" : "/"),
    }
  end
end
