class SlackAttachmentBuilder
  def self.build(&)
    builder = new
    builder.instance_eval(&) if block_given?
    builder.blocks
  end

  def initialize
    @blocks = []
  end

  def header(str)
    @blocks << {
      type: :header,
      text: {
        type: :plain_text,
        text: str,
      },
    }
  end

  def text(str)
    @blocks << {
      type: :section,
      text: {
        type: :mrkdwn,
        text: str,
      },
    }
  end

  def fields(*fields)
    @blocks << {
      type:   :section,
      fields: fields.map { |field|
        {
          type: :mrkdwn,
          text: field.to_s,
        }
      },
    }
  end

  def context(*elements)
    @blocks << {
      type:     :context,
      elements: elements.map { |element|
        {
          type: :mrkdwn,
          text: element.to_s,
        }
      },
    }
  end

  def divider
    @blocks << { type: :divider }
  end

  def button(str, url)
    @blocks << # This only supports a single inline button. Will have to refactor if we want multiple.
      {
        type:     :actions,
        elements: [
          {
            type: :button,
            text: {
              type: :plain_text,
              text: str,
            },
            url:  url,
          },
        ],
      }
  end

  def buttons(*buttons)
    @blocks << {
      type:     :actions,
      elements: buttons.map { |str, url|
        {
          type: :button,
          text: {
            type: :plain_text,
            text: str,
          },
          url:  url,
        }
      },
    }
  end

  def progress(percent, width=40)
    filled_pixels = ((percent / 100.0) * (width - 1)).ceil.clamp(0, width)
    filled_pixels += 1 if percent >= 100
    empty_pixels = width - filled_pixels

    progress_bar = ("▰" * filled_pixels) + ("▱" * empty_pixels)
    text("[#{progress_bar}] #{percent.round}%")
  end

  def link(str, url=nil)
    @blocks << url ||= str
    "<#{url}|#{str}>"
  end
end
