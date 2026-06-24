# frozen_string_literal: true

require "rails_helper"

RSpec.describe RakeTaskRunner do
  let(:task) { instance_double(Rake::Task, invoke: nil, reenable: nil) }

  before do
    allow(Rails.application).to receive(:load_tasks)
    allow(Rake::Task).to receive(:task_defined?).with("db:dump").and_return(true)
    allow(Rake::Task).to receive(:[]).with("db:dump").and_return(task)
  end

  it "loads tasks, reenables, and invokes by name" do
    allow(Rake::Task).to receive(:task_defined?).with("db:dump").and_return(false)

    described_class.invoke("db:dump")

    expect(Rails.application).to have_received(:load_tasks)
    expect(task).to have_received(:reenable)
    expect(task).to have_received(:invoke)
  end

  it "skips load_tasks when the task is already defined" do
    allow(Rake::Task).to receive(:task_defined?).with("db:dump").and_return(true)

    described_class.invoke("db:dump")

    expect(Rails.application).not_to have_received(:load_tasks)
  end
end
