# frozen_string_literal: true

# A stand-in for Ollama's /api/generate on 127.0.0.1 for a `graph_mem:scan_profile` run with no
# model (F-3b, step B): every scan part is answered from GraphMem::ScanProfile::SynthRepo's canned
# answers, or SynthRailsRepo's for a part of its project (1.75.0), so only the generated repos give
# meaningful results. Plain Ruby (stdlib only), no Rails.
#
#   ruby script/scan_profile/fake_ollama.rb 3995 &
#   SUMMARY_URL=http://127.0.0.1:3995 bin/rails graph_mem:scan_profile REPOS=synth
#
# Specs start it in a thread: `ScanProfileFakeOllama.start(0)` (an ephemeral port).
require "json"
require "socket"
require_relative "../../lib/graph_mem/scan_profile/synth_repo"
require_relative "../../lib/graph_mem/scan_profile/synth_rails_repo"

# The fake server: one thread, one request per connection.
class ScanProfileFakeOllama
  # @return [Integer] the bound port
  attr_reader :port

  # @return [Integer] the requests answered
  attr_reader :requests

  # @param port [Integer] 0 for an ephemeral port
  # @return [ScanProfileFakeOllama] listening on 127.0.0.1
  def self.start(port)
    new(port).tap(&:listen)
  end

  # @param port [Integer]
  def initialize(port)
    @server = TCPServer.new("127.0.0.1", port)
    @port = @server.addr[1]
    @requests = 0
  end

  # @return [String] the base URL
  def url = "http://127.0.0.1:#{@port}"

  # @return [Thread]
  def listen
    @thread = Thread.new { loop { serve(@server.accept) } }
  end

  # @return [void]
  def stop
    @thread&.kill
    @server.close
  end

  private

  def serve(socket)
    request_line = socket.gets.to_s
    headers = {}
    while (line = socket.gets) && line != "\r\n"
      name, value = line.split(":", 2)
      headers[name.to_s.strip.downcase] = value.to_s.strip
    end
    body = socket.read(headers["content-length"].to_i).to_s
    status, payload = answer(request_line.split[0], request_line.split[1], body)
    text = JSON.generate(payload)
    socket.write("HTTP/1.1 #{status} #{status == 200 ? 'OK' : 'Not Found'}\r\nContent-Type: application/json\r\n" \
                 "Content-Length: #{text.bytesize}\r\nConnection: close\r\n\r\n#{text}")
  rescue StandardError
    nil
  ensure
    socket&.close
  end

  def answer(method, path, body)
    return [ 404, { error: "not found" } ] unless method == "POST" && path == "/api/generate"

    @requests += 1
    prompt = JSON.parse(body)["prompt"].to_s
    repo = GraphMem::ScanProfile::SynthRailsRepo.prompt?(prompt) ? GraphMem::ScanProfile::SynthRailsRepo : GraphMem::ScanProfile::SynthRepo
    stub = repo.stub_answer(prompt)
    [ 200, { model: "fake-model", response: stub[:text], done: true, done_reason: stub[:done_reason],
             prompt_eval_count: prompt.bytesize / 4, eval_count: stub[:text].bytesize / 4 } ]
  end
end

if $PROGRAM_NAME == __FILE__
  server = ScanProfileFakeOllama.start(Integer(ARGV.fetch(0, "3995")))
  warn "fake Ollama on #{server.url} (synth answers only); Ctrl-C to stop"
  trap("INT") do
    server.stop
    exit
  end
  sleep
end
