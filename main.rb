require 'async'
require 'async/io'
require 'parallel'
require 'net/http'
require 'typhoeus'
require 'async/barrier'
require 'async/http/internet/instance'
require 'ruby-prof'
require 'benchmark/ips'
require "gvl-tracing"

# TRACE_SYSTEM_CALL = "sudo ./bcc/tools/lib/ucalls.py -l ruby -S #{$$}"
# TRACE_UFLOW = "sudo ./bcc/tools/lib/ucalls.py -l ruby -p #{$$}"
# ucalls_io = IO.popen("sudo perf trace -s -p #{$$}", 'r+')

# sleep 3
ENDPOINT = 'https://1060ki.com'.freeze
ITERATIONS = 10
Benchmark.ips do |x|
  x.config(time: 10, warmup: 2)
  x.report("async/#{ITERATIONS}") do
    Sync do
      internet = Async::HTTP::Internet.instance
      barrier = Async::Barrier.new
      semaphore = Async::Semaphore.new(50, parent: barrier)
      statuses = ITERATIONS.times.map do
        semaphore.async do
          r = internet.get(ENDPOINT)
          r.close
          r.status
        rescue StandardError => e
          puts e
        end
      end.map(&:wait)

      barrier.stop
      raise if statuses.size != ITERATIONS || statuses.any? { |s| s != 200 }
    ensure
      internet&.close
    end
  end
  x.report("typhoeus/#{ITERATIONS}") do
    hydra = Typhoeus::Hydra.new(max_concurrency: 50)
    requests = ITERATIONS.times.map do
      request = Typhoeus::Request.new(ENDPOINT, http_version: :httpv2_0)
      hydra.queue(request)
      request
    end
    hydra.run
    responses = requests.map do |request|
      request.response
    end
    raise if responses.size != ITERATIONS || responses.any? { |r| !r.success? }
  end
  x.report("parallel(thread)/#{ITERATIONS}") do
    responses = Parallel.map(ITERATIONS.times, in_threads: 8) do
      res = Typhoeus.get(ENDPOINT)
      res
    end
    raise if responses.size != ITERATIONS || responses.any? { |r| !r.success? }
  end
end

Benchmark.ips do |x|
  x.config(time: 5, warmup: 2)
  x.report 'fiber' do
    writable = {}
    readable = {}
    ITERATIONS.times do
      s = TCPSocket.new '127.0.0.1', 3000
      writable[s] = Fiber.new do
        s.write_nonblock "GET / HTTP/1.1\r\n\r\n"
        readable[s] = Fiber.new do
          s.read_nonblock(1024)
          s.close
          readable.delete s
        end
        writable.delete s
      rescue IO::WaitWritable, IO::WaitReadable
        Fiber.yield
        retry
      end
    end

    loop do
      break if writable.empty? && readable.empty?

      r, w = IO.select readable.keys, writable.keys
      w.each do |s|
        writable[s].resume
      end

      r.each do |s|
        readable[s].resume
      end
    end
  end
  x.report 'thread' do
    threads = []
    ITERATIONS.times do
      threads << Thread.new do
        s = TCPSocket.open '127.0.0.1', 3000
        s.write "GET / HTTP/1.1\r\n\r\n"
        s.close_write
        s.read
        s.close
      end
    end
    threads.each(&:join)
  end
end
x.report 'async' do
  endpoint = Async::IO::Endpoint.tcp('127.0.0.1', 3000)

  Sync do |t|
    ITERATIONS.times.map do |i|
      t.async do
        endpoint.connect do |peer|
          peer.write("GET / HTTP/1.1\r\n\r\n")
          peer.close_write
          peer.read
          peer.close
        end
      end
    end.each(&:wait)
  end
end
# Process.kill('SIGINT', ucalls_io.pid)
# Process.wait(ucalls_io.pid)
# puts ucalls_io.read
# ucalls_io.close
