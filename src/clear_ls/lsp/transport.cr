require "json"

module ClearLS::LSP
  # Reads and writes LSP base-protocol messages (`Content-Length` framing).
  class Transport
    class ProtocolError < Exception
    end

    def initialize(@input : IO, @output : IO)
      @write_lock = Mutex.new
    end

    # Next message body, or `nil` at end of input.
    def read : String?
      length = nil
      loop do
        line = @input.gets(chomp: true)
        return nil if line.nil?
        break if line.empty?
        name, _, value = line.partition(':')
        if name.strip.compare("Content-Length", case_insensitive: true) == 0
          length = value.strip.to_i? || raise ProtocolError.new("bad Content-Length: #{value}")
        end
      end
      raise ProtocolError.new("missing Content-Length") unless length
      body = Bytes.new(length)
      @input.read_fully(body)
      String.new(body)
    rescue IO::EOFError
      nil
    end

    def write(body : String) : Nil
      @write_lock.synchronize do
        @output << "Content-Length: " << body.bytesize << "\r\n\r\n" << body
        @output.flush
      end
    end
  end
end
