require "rails_helper"

# One send, one message, however many times the client asks.
#
# The client mints a `local_id` per composed message and its outbound queue
# retries on any uncertain outcome — a dropped response, a PWA backgrounded
# mid-send, a double-fired tap. queue.js has always documented the other half of
# that contract as ours: "the server treats a repeat with the same local_id as
# idempotent." It didn't.
#
# Prod 3781/3783: one send, two rows, same local_id and the same client-stamped
# created_at to the millisecond. Two rows meant two turns, two replies, and
# "light covers" put on the agenda twice. It had happened once before, in July
# (1397/1399), and nothing in the thread says which of the pair is real.
RSpec.describe ByteMessageIntake do
  let(:user)  { User.me }
  let(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current) }
  let(:lid)   { "922cfa6d-ba39-43c4-999c-6aad98724c3d" }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(BuddyDeliverWorker).to receive(:perform_async)
  end

  def send!(body, local_id: lid, conversation: convo)
    described_class.call(
      user:         user,
      conversation: conversation,
      body:         body,
      metadata:     ({ local_id: local_id } if local_id).to_h,
    )
  end

  it "creates one row when the same send arrives twice" do
    first = send!("Also add light covers")

    expect { send!("Also add light covers") }.not_to change(ByteMessage, :count)
    expect(send!("Also add light covers").id).to eq(first.id)
  end

  # The duplicate turn is what actually cost something: two replies, and the
  # task on the agenda twice.
  it "runs the turn once" do
    send!("Also add light covers")
    send!("Also add light covers")

    expect(BuddyDeliverWorker).to have_received(:perform_async).once
  end

  it "hands back the row the client is waiting for, not nil" do
    first = send!("Also add light covers")
    again = send!("Also add light covers")

    expect(again).to be_a(ByteMessage)
    expect(again.body).to eq(first.body)
  end

  # A retry can carry different text only if something is badly wrong; the id is
  # the identity, and the row that already exists is the one the thread shows.
  it "keeps the first body when a repeat carries different text" do
    first = send!("Also add light covers")

    expect(send!("something else entirely").id).to eq(first.id)
    expect(first.reload.body).to eq("Also add light covers")
  end

  it "leaves genuinely separate sends alone" do
    send!("first thing", local_id: SecureRandom.uuid)

    expect { send!("second thing", local_id: SecureRandom.uuid) }.to change(ByteMessage, :count).by(1)
  end

  # The Mac CLI door (/webhooks/byte/say) doesn't mint one, and two identical
  # messages typed twice on purpose are two messages.
  it "does not dedupe when there's no local_id at all" do
    send!("ok", local_id: nil)

    expect { send!("ok", local_id: nil) }.to change(ByteMessage, :count).by(1)
  end

  # A local_id is only unique within the client that minted it.
  it "scopes the key to the conversation" do
    other = user.byte_conversations.create!(mode: :buddy, name: "Other")
    send!("Also add light covers")

    expect { send!("Also add light covers", conversation: other) }.to change(ByteMessage, :count).by(1)
  end

  # Belt and braces for the case the check at the top can't catch: two requests
  # in flight together, both finding nothing. The index is what settles it, and
  # the send still has to come back as delivered rather than a 500.
  it "survives a race that gets past the check" do
    first = send!("Also add light covers")
    allow_any_instance_of(described_class).to receive(:existing_for_local_id).and_return(nil, first)

    expect { expect(send!("Also add light covers").id).to eq(first.id) }
      .not_to change(ByteMessage, :count)
  end
end
