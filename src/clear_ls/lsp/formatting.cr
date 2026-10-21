require "./diagnostics"

module ClearLS::LSP
  # `textDocument/formatting` through `crystal tool format -`.
  class Server
    private def formatting(params : JSON::Any)
      state = document(params)
      text = state.text
      result = toolchain.format(text).wait
      unless result.success?
        reason = result.launch_error || result.stderr.lines.first?.try(&.strip) || "exit #{result.exit_code}"
        Log.info { "format #{state.uri}: #{reason}" }
        notify_log(3, "crystal tool format: #{reason}")
        return nil
      end
      edit = minimal_edit(text, result.stdout) || return [] of Nil
      range, new_text = edit
      [{range: range_json(state, range), newText: new_text}]
    end

    # One edit replacing the lines that differ between *old* and *new*.
    # Keeping the unchanged prefix and suffix keeps the client's cursor and
    # marks where they were.
    def self.line_diff(old : String, new : String) : {TextRange, String}?
      return nil if old == new
      a = old.lines(chomp: false)
      b = new.lines(chomp: false)
      prefix = 0
      while prefix < a.size && prefix < b.size && a[prefix] == b[prefix]
        prefix += 1
      end
      suffix = 0
      while suffix < a.size - prefix && suffix < b.size - prefix && a[a.size - 1 - suffix] == b[b.size - 1 - suffix]
        suffix += 1
      end
      start = a[0, prefix].sum(&.bytesize).to_u32
      stop = old.bytesize.to_u32 - a[a.size - suffix, suffix].sum(&.bytesize).to_u32
      {TextRange.new(start, stop), b[prefix, b.size - prefix - suffix].join}
    end

    private def minimal_edit(old : String, new : String)
      Server.line_diff(old, new)
    end

    # window/logMessage (type 1 error .. 4 log).
    private def notify_log(type : Int32, message : String) : Nil
      @transport.write(JsonRpc.notification("window/logMessage", {type: type, message: message}))
    end
  end
end
