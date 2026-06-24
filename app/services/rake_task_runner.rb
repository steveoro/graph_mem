# frozen_string_literal: true

require "rake"

# Invokes Rails rake tasks from application code (jobs, controllers).
# Rake is not loaded in the Puma process by default, so callers must go through here.
module RakeTaskRunner
  module_function

  def invoke(task_name)
    Rails.application.load_tasks unless Rake::Task.task_defined?(task_name)

    task = Rake::Task[task_name]
    task.reenable
    task.invoke
  end
end
