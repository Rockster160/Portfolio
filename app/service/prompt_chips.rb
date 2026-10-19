# A prompt's `chips` question: one choice from a few short ones, drawn as a row
# of tappable chips rather than a dropdown. Each chip is grey until it's picked
# and then lights up in its own color.
#
# A chip that names a household member takes that person's color without being
# told, so a "Who did it?" reads at a glance the way the chore cards do. The
# colors are the `[data-actor]` ones in chores.scss.
module PromptChips
  module_function

  ACTOR_COLORS = {
    "Rockster160"  => "#0160FF",
    "Alchemibluum" => "#A082D9",
  }.freeze

  HEX = /\A#\h{3}(?:\h{3})?\z/

  # choice => color, for the choices that have one. `given` wins over the
  # person's own color, and anything that isn't a hex color is dropped rather
  # than written into a style attribute.
  def colors(choices, given={})
    named = given.respond_to?(:to_h) ? given.to_h.transform_keys(&:to_s) : {}
    Array(choices).each_with_object({}) { |choice, acc|
      color = named[choice.to_s].presence || ACTOR_COLORS[choice.to_s]
      acc[choice.to_s] = color if color.to_s.match?(HEX)
    }
  end
end
