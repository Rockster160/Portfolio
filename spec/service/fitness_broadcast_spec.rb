require "rails_helper"

# Only the applications row is covered here. Every other row is an event query
# that predates this file; this is the one reading the job tracker instead, and
# it is the one whose day boundary and goal are worth pinning down.
RSpec.describe FitnessBroadcast do
  let(:user) { create(:user) }
  let(:zone) { ActiveSupport::TimeZone["America/Denver"] }
  let(:job) { user.job_applications.create!(company: "Acme") }

  before { allow(User).to receive(:me).and_return(user) }

  def applied(at, on: job)
    on.notes.create!(tag: :applied, occurred_at: at)
  end

  # `dates` reverses, so the row reads newest-first and TODAY is the leftmost
  # pair. Each cell renders as "[color #HEX]  4[/color]".
  def cells
    row = described_class.fitness_data.find { |line| line.start_with?("💼") }
    row.to_s.scan(/\[color (#\w+)\]\s*(\S+)\[\/color\]/)
  end

  it "counts the day's applications, and reads green once the goal is met" do
    travel_to(zone.local(2026, 9, 15, 10)) do
      5.times { applied(zone.local(2026, 9, 15, 9)) }

      expect(cells.first).to eq(["#148F14", "5"])
    end
  end

  # The number, not a tick — five is a good day, not the end of one, and a ✓
  # at five reads identically to a ✓ at nine.
  it "keeps showing the count past the goal" do
    travel_to(zone.local(2026, 9, 15, 10)) do
      9.times { applied(zone.local(2026, 9, 15, 9)) }

      expect(cells.first).to eq(["#148F14", "9"])
    end
  end

  it "reads amber short of the goal" do
    travel_to(zone.local(2026, 9, 15, 10)) do
      2.times { applied(zone.local(2026, 9, 15, 9)) }

      expect(cells.first).to eq(["#FFA001", "2"])
    end
  end

  it "reads red on a day nobody applied" do
    travel_to(zone.local(2026, 9, 15, 10)) do
      job # the board exists; nothing was sent

      expect(cells.first).to eq(["#F81414", "-"])
    end
  end

  # Every other beat of an application is something that happened TO him. Only
  # `applied` is the thing this row is counting.
  it "counts only the applied tag" do
    travel_to(zone.local(2026, 9, 15, 10)) do
      job.notes.create!(tag: :interview, occurred_at: zone.local(2026, 9, 15, 9))
      job.notes.create!(tag: :rejected, occurred_at: zone.local(2026, 9, 15, 9))

      expect(cells.first).to eq(["#F81414", "-"])
    end
  end

  it "leaves out other people's boards" do
    travel_to(zone.local(2026, 9, 15, 10)) do
      other = create(:user).job_applications.create!(company: "Globex")
      applied(zone.local(2026, 9, 15, 9), on: other)

      expect(cells.first).to eq(["#F81414", "-"])
    end
  end

  # The cell's day turns at 4am, not midnight. An application sent at 2am was
  # sent on the night before, and is what that night is judged on.
  it "puts a 2am application on the night before" do
    travel_to(zone.local(2026, 9, 15, 10)) do
      applied(zone.local(2026, 9, 15, 2))

      expect(cells[0]).to eq(["#F81414", "-"])
      expect(cells[1]).to eq(["#FFA001", "1"])
    end
  end

  # Seven days wide, same as every other row — the week is the point of the
  # cell, not just today.
  it "carries the whole week" do
    travel_to(zone.local(2026, 9, 15, 10)) do
      applied(zone.local(2026, 9, 15, 9))
      applied(zone.local(2026, 9, 11, 9))

      expect(cells.length).to eq(7)
      expect(cells[4]).to eq(["#FFA001", "1"])
    end
  end
end
