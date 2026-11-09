# frozen_string_literal: true

module GraphMem
  module ScanProfile
    # The progress lines of one profiled scan (1.75.0). A real scan on CPU-only Ollama can spend
    # 5-10 minutes in one model request, and the run printed nothing until a whole repo × profile
    # was done, so a working run looked stuck. Now it prints:
    #
    # - each step ProjectScanner reports (`on_progress:`): discovering and reading files, "part k of
    #   n" as each request starts, reconciling, completed;
    # - each part's end (`on_part_done:`): done or failed (with the reason), its time, and whether it
    #   was split in two;
    # - a heartbeat every HEARTBEAT_SECONDS while the scan runs, with the step and the time so far.
    #
    # Only counts, steps and the scanner's own messages: no file names or contents.
    #
    #   progress = Progress.new("goggles_db code initial", out: $stdout)
    #   progress.watch { ProjectScanner.new(…, on_progress: progress.method(:phase), on_part_done: …).call }
    #   # [scan_profile] goggles_db code initial: Extracting knowledge: part 2 of 6
    #   # [scan_profile] goggles_db code initial: still working (Extracting knowledge: part 2 of 6; 7 min so far)
    #   # [scan_profile] goggles_db code initial: part 2 of 6 done in 412 s
    class Progress
      HEARTBEAT_SECONDS = 60
      PREFIX = "[scan_profile]"

      # @param label [String] the repo, profile and scan mode
      # @param out [IO, nil] where the lines go; nil prints nothing (and starts no heartbeat)
      def initialize(label, out:)
        @label = label
        @out = out
        @step = "starting"
        @lock = Mutex.new
      end

      # Runs the scan with a heartbeat thread beside it.
      #
      # @yieldreturn [Object] the scan's result
      # @return [Object] the block's value
      def watch
        @started = monotonic
        ticker = start_ticker if @out
        yield
      ensure
        ticker&.kill
      end

      # ProjectScanner's `on_progress:`.
      #
      # @param _phase [String]
      # @param message [String]
      # @return [void]
      def phase(_phase, message)
        return if message.to_s == @step

        @step = message.to_s
        say(@step)
      end

      # ProjectScanner's `on_part_done:`.
      #
      # @param done [ProjectScanner::ChunkedExtraction::PartDone]
      # @return [void]
      def part_done(done)
        outcome = done.error ? "failed (#{Report.scrub(done.error)})" : "done"
        say("part #{done.part} of #{done.parts} #{outcome} in #{done.seconds.round} s#{'; split in two' if done.split}")
      end

      private

      def start_ticker
        Thread.new do
          loop do
            sleep(HEARTBEAT_SECONDS)
            heartbeat
          end
        end
      end

      def heartbeat
        say("still working (#{@step}; #{((monotonic - @started) / 60).floor} min so far)")
      end

      def say(text)
        return unless @out

        @lock.synchronize do
          @out.puts("#{PREFIX} #{@label}: #{text}")
          @out.flush if @out.respond_to?(:flush)
        end
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
