require "json"

module ClearLS::Compiler
  # A location in compiler output: 1-based line, 1-based column counted in
  # codepoints. *size* is the highlighted width in codepoints (0 or nil when
  # the compiler gives none).
  record Frame, file : String, line : Int32, column : Int32, size : Int32?, message : String

  enum Severity
    Error
    Warning
  end

  # One reported problem. *trace* holds the frames that led to it
  # (instantiations, macro expansions), outermost first.
  record Problem, severity : Severity, frame : Frame, trace : Array(Frame) do
    def file : String
      frame.file
    end

    def message : String
      frame.message
    end
  end

  # Parsers for `crystal build --no-codegen -f json --no-color` output.
  #
  # Errors are a JSON array of frames on stderr: the exception chain from
  # the outermost instantiation to the actual error. Warnings are always
  # text (`-f json` does not cover them).
  module Output
    MACRO_FRAME = "expanding macro"

    # The JSON frame array in *stderr*, or nil when there is none (the
    # compiler crashed, or failed before semantic analysis, e.g. a missing
    # main file, which is reported as plain text).
    def self.error_frames(stderr : String) : Array(Frame)?
      stderr.each_line do |line|
        line = line.strip
        next unless line.starts_with?("[{") && line.ends_with?("}]")
        json = JSON.parse(line) rescue next
        return json.as_a.compact_map { |f| frame(f) }
      end
      nil
    end

    # The problem for a compile error: the last frame, except that a frame
    # following an "expanding macro" frame points into the macro's
    # expansion (a virtual file whose lines are reported against the real
    # file name), so the expansion's call site is used instead.
    def self.error(frames : Array(Frame)) : Problem?
      last = frames.last? || return
      trace = frames[0...-1]
      if (site = trace.last?) && site.message == MACRO_FRAME
        # Nested expansions at one call site repeat it; the outermost frame
        # carries the call's width.
        while (t = trace.last?) && t.message == MACRO_FRAME && t.file == site.file && t.line == site.line
          site = trace.pop
        end
        last = Frame.new(site.file, site.line, site.column, site.size, last.message)
      end
      Problem.new(Severity::Error, last, trace)
    end

    # Warnings in the text report:
    #
    # ```text
    # In src/two.cr:3:1
    #
    #  3 | old
    #      ^--
    # Warning: Deprecated ::old. x
    # ```
    #
    # Relative file names are relative to the compiler's working directory
    # *base_dir*.
    def self.warnings(text : String, base_dir : String) : Array(Problem)
      problems = [] of Problem
      location = nil.as({String, Int32, Int32}?)
      size = nil.as(Int32?)
      text.each_line do |line|
        if m = line.match(/^In (.+):(\d+):(\d+)$/)
          location = {File.expand_path(m[1], base_dir), m[2].to_i, m[3].to_i}
          size = nil
        elsif m = line.match(/^\s+(\^-*)\s*$/)
          size = m[1].size
        elsif line.starts_with?("Warning: ") && (loc = location)
          frame = Frame.new(loc[0], loc[1], loc[2], size, line.lchop("Warning: "))
          problems << Problem.new(Severity::Warning, frame, [] of Frame)
          location = nil
        end
      end
      problems
    end

    private def self.frame(json : JSON::Any) : Frame?
      file = json["file"]?.try(&.as_s?) || return
      line = json["line"]?.try(&.as_i?) || return
      column = json["column"]?.try(&.as_i?) || 1
      size = json["size"]?.try(&.as_i?)
      message = json["message"]?.try(&.as_s?) || ""
      Frame.new(file, line, column, size, message)
    end
  end
end
