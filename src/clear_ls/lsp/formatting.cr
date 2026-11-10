require "./diagnostics"

module ClearLS::LSP
  # `textDocument/formatting` and `textDocument/rangeFormatting` through
  # `crystal tool format -`.
  class Server
    private def formatting(params : JSON::Any)
      state = document(params)
      text = state.text
      formatted = format_text(state) || return nil
      edit = minimal_edit(text, formatted) || return [] of Nil
      range, new_text = edit
      [{range: range_json(state, range), newText: new_text}]
    end

    # The formatter has no range option and needs the whole source
    # (indentation, alignment): format the buffer, keep the hunks that
    # touch the requested lines (conform.nvim's approach).
    private def range_formatting(params : JSON::Any)
      state = document(params)
      text = state.text
      formatted = format_text(state) || return nil
      r = params["range"]
      first = r.dig("start", "line").as_i
      last = r.dig("end", "line").as_i
      # A range ending at column 0 of a line does not select that line.
      last -= 1 if last > first && r.dig("end", "character").as_i == 0
      a = text.lines(chomp: false)
      starts = [0_u32]
      a.each { |l| starts << starts.last + l.bytesize }
      Server.hunks_in_range(text, formatted, first, last).map do |h|
        range = TextRange.new(starts[h.old_start], starts[h.old_start + h.old_count])
        {range: range_json(state, range), newText: h.new_text}
      end
    end

    # Formatted buffer, or nil (logged) when the formatter fails.
    private def format_text(state : FileState) : String?
      result = toolchain.format(state.text).wait
      return result.stdout if result.success?
      reason = result.launch_error || result.stderr.lines.first?.try(&.strip) || "exit #{result.exit_code}"
      Log.info { "format #{state.uri}: #{reason}" }
      notify_log(3, "crystal tool format: #{reason}")
      nil
    end

    # A changed run of lines: *old_count* lines from *old_start* (0-based)
    # become *new_text*.
    record Hunk, old_start : Int32, old_count : Int32, new_text : String

    # Every hunk between *old* and *new*, line by line (Myers' diff on the
    # lines between the common prefix and suffix).
    def self.line_hunks(old : String, new : String) : Array(Hunk)
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
      x = a[prefix, a.size - prefix - suffix]
      y = b[prefix, b.size - prefix - suffix]
      hunks = [] of Hunk
      i = j = 0
      pending = nil.as({Int32, Int32, Int32}?) # old start, old count, new start
      flush = ->(ni : Int32) {
        if p = pending
          hunks << Hunk.new(prefix + p[0], p[1], y[p[2]...ni].join)
          pending = nil
        end
      }
      myers(x, y).each do |op|
        case op
        when :keep
          flush.call(j)
          i += 1
          j += 1
        when :del
          pending ||= {i, 0, j}
          p = pending.not_nil!
          pending = {p[0], p[1] + 1, p[2]}
          i += 1
        else # :ins
          pending ||= {i, 0, j}
          j += 1
        end
      end
      flush.call(j)
      hunks
    end

    # Edit script (:keep, :del, :ins) turning *x* into *y*, shortest first.
    private def self.myers(x : Array(String), y : Array(String)) : Array(Symbol)
      n, m = x.size, y.size
      max = n + m
      v = Array(Int32).new(2 * max + 2, 0)
      trace = [] of Array(Int32)
      (0..max).each do |d|
        # Only diagonals -d..d are read at step d: keep that slice
        # (O(D²) memory instead of O(D·(N+M))).
        trace << v[max - d, 2 * d + 1]
        (-d..d).step(2) do |k|
          xi = if k == -d || (k != d && v[k - 1 + max] < v[k + 1 + max])
                 v[k + 1 + max]
               else
                 v[k - 1 + max] + 1
               end
          yi = xi - k
          while xi < n && yi < m && x[xi] == y[yi]
            xi += 1
            yi += 1
          end
          v[k + max] = xi
          if xi >= n && yi >= m
            return backtrack(trace, x.size, y.size)
          end
        end
      end
      [] of Symbol
    end

    private def self.backtrack(trace : Array(Array(Int32)), n : Int32, m : Int32) : Array(Symbol)
      ops = [] of Symbol
      xi, yi = n, m
      (trace.size - 1).downto(0) do |d|
        v = trace[d] # v[i] is diagonal i - d
        k = xi - yi
        prev_k = if k == -d || (k != d && v[k - 1 + d] < v[k + 1 + d])
                   k + 1
                 else
                   k - 1
                 end
        prev_x = d == 0 ? 0 : v[prev_k + d]
        prev_y = prev_x - prev_k
        while xi > prev_x && yi > prev_y
          ops << :keep
          xi -= 1
          yi -= 1
        end
        if d > 0
          ops << (xi == prev_x ? :ins : :del)
        end
        xi, yi = prev_x, prev_y
      end
      ops.reverse!
    end

    # Hunks touching lines *first*..*last* (0-based, inclusive): a
    # replacement or deletion overlapping them, an insertion at or right
    # after them. Each kept hunk extends the window to its end, so a
    # deletion/insertion pair is kept together.
    def self.hunks_in_range(old : String, new : String, first : Int32, last : Int32) : Array(Hunk)
      line_hunks(old, new).select do |h|
        h_last = h.old_count == 0 ? h.old_start : h.old_start + h.old_count - 1
        h_first = h.old_count == 0 ? h.old_start - 1 : h.old_start
        keep = h_first <= last && first <= h_last
        last = {last, h.old_start + h.old_count}.max if keep
        keep
      end
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
