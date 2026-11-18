require "rails_helper"

RSpec.describe "generate_image tool" do
  let(:user) { create(:user) }
  let(:conversation) {
    user.byte_conversations.create!(mode: :buddy, name: "Byte", last_message_at: Time.current)
  }
  let(:ctx)    { Buddy::ToolContext.new(user, conversation: conversation) }
  let(:tool)   { Buddy::Tools[:generate_image] }
  let(:images) { instance_double(OpenAI::Images) }
  let(:png)    { "\x89PNG fake bytes".b }
  let(:response) {
    {
      "data"  => [{ "b64_json" => Base64.strict_encode64(png) }],
      "usage" => { "input_tokens" => 40, "output_tokens" => 1000 },
    }
  }

  before do
    allow(WebPushNotifications).to receive(:send_to_byte)
    allow(Buddy::ActivityChip).to receive(:broadcast)
    allow(OpenAI::Client).to receive(:new).and_return(instance_double(OpenAI::Client, images: images))
    allow(images).to receive(:generate).and_return(response)
  end

  def execute(payload)
    tool[:execute].call(tool[:confirm].call(payload, ctx)[:resolved], ctx)
  end

  it "draws the picture and posts it into the thread" do
    result = execute({ prompt: "A single blue rose on a black background", caption: "Blue rose" })

    message = conversation.byte_messages.find(result[:message_id])
    expect(message.body).to eq("Blue rose")
    expect(message.metadata["source"]).to eq("generated_image")
    expect(message.files.first.download).to eq(png)
    expect(message.files.first.content_type).to eq("image/png")
    expect(result[:drawn]).to eq("Blue rose")
  end

  it "asks for a square medium picture on the image model unless told otherwise" do
    execute({ prompt: "A blue rose" })

    expect(images).to have_received(:generate).with(
      parameters: hash_including(model: "gpt-image-2", size: "1024x1024", quality: :medium, n: 1),
    )
  end

  it "draws tall and wide pictures when asked" do
    execute({ prompt: "A blue rose", shape: :portrait })
    expect(images).to have_received(:generate).with(parameters: hash_including(size: "1024x1536"))

    execute({ prompt: "A blue rose", shape: :landscape })
    expect(images).to have_received(:generate).with(parameters: hash_including(size: "1536x1024"))
  end

  it "files the picture under its prompt so it can be found again" do
    result = execute({ prompt: "A single blue rose" })

    description = ImageDescription.find_by(byte_message_id: result[:message_id])
    expect(description.body).to include("A single blue rose")
    expect(description.tags).to include("generated")
  end

  it "records the spend as its own kind, priced on the image model" do
    execute({ prompt: "A blue rose" })

    usage = BuddyUsage.where(user: user).last
    expect(usage).to be_image_generate
    expect(usage.model).to eq("gpt-image-2")
    expect(usage.byte_conversation).to eq(conversation)
    expect(usage.cost_micros).to eq(30_200)
  end

  it "posts nothing and says why when the model refuses" do
    error = Faraday::BadRequestError.new(
      "400",
      { status: 400, body: { error: { message: "Your request was rejected by the safety system." } }.to_json },
    )
    allow(images).to receive(:generate).and_raise(error)

    result = execute({ prompt: "Something it won't draw" })

    expect(result[:drawn]).to be_nil
    expect(result[:error]).to include("rejected by the safety system")
    expect(conversation.byte_messages.count).to eq(0)
  end

  it "refuses to draw without a description" do
    expect { tool[:confirm].call({ prompt: " " }, ctx) }.to raise_error(/what to draw/)
  end
end
