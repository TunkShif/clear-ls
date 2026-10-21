require "./diagnostics"

module ClearLS::LSP
  # `clearLs/expandMacro {textDocument, position}` → macro expansion at the
  # position via `crystal tool expand`, on the saved file.
  #
  # Result:
  #
  # ```json
  # {"status": "ok" | "failed", "message": "...",
  #  "expansions": [{"original": "getter(x : Int32)",
  #                  "steps": [{"source": "...", "macros": [{"name", "location"}]}]}]}
  # ```
  #
  # Each step is one level of expansion (nested macro calls expand in later
  # steps). Hook macros (`inherited`, `included`, `finished`) are not found
  # by the compiler tool.
  class Server
    private def expand_macro(params : JSON::Any)
      uri = params.dig("textDocument", "uri").as_s
      path = VFS.path_for(uri) || raise ResponseError.new(ErrorCode::InvalidParams, "not a file: #{uri}")
      raise ResponseError.new(ErrorCode::InvalidParams, "file not saved: #{uri}") unless File.file?(path)
      saved = File.read(path)
      if (state = @vfs.file?(uri)) && state.overlay? && state.text != saved
        raise ResponseError.new(ErrorCode::ContentModified, "save the file first: the compiler expands the saved file")
      end
      lines = LineIndex.new(saved)
      offset = lines.offset(position(params["position"]), @encoding)
      pos = lines.position(offset, PositionEncoding::UTF32)
      entry = (program_entries(uri) || [path]).first
      job = toolchain.expand(entry, path, pos.line.to_i + 1, pos.column.to_i + 1)
      Deferred.new { expansion_json(job.wait) }
    end

    private def expansion_json(result : Compiler::Job::Result) : JSON::Any
      unless result.completed?
        raise ResponseError.new(ErrorCode::RequestFailed, result.launch_error || (result.timed_out ? "crystal tool expand timed out" : "cancelled"))
      end
      json = JSON.parse(result.stdout) rescue nil
      unless json && json["status"]?
        # The program does not compile: the error frames are on stderr.
        message = Compiler::Output.error_frames(result.stderr).try { |f| Compiler::Output.error(f).try(&.message) } ||
                  result.stderr.lines.first?.try(&.strip) || "crystal tool expand failed"
        return JSON.parse({status: "failed", message: "program does not compile: #{message}", expansions: [] of Nil}.to_json)
      end
      expansions = json["expansions"]?.try(&.as_a) || [] of JSON::Any
      JSON.parse({
        status:     json["status"].as_s,
        message:    json["message"]?.try(&.as_s) || "",
        expansions: expansions.map { |e| expansion_entry(e) },
      }.to_json)
    end

    private def expansion_entry(e : JSON::Any)
      sources = e["expanded_sources"].as_a
      macros = e["expanded_macros"]?.try(&.as_a) || [] of JSON::Any
      steps = sources.each_with_index.map do |src, i|
        used = macros[i]?.try(&.as_a) || [] of JSON::Any
        {
          source: src.as_s,
          macros: used.map do |m|
            impl = m["implementation"]
            line = (impl["line"].as_i - 1).clamp(0, nil)
            col = (impl["column"].as_i - 1).clamp(0, nil)
            {
              name:     m["name"].as_s,
              location: {
                uri:   VFS.uri_for(impl["filename"].as_s),
                range: {start: {line: line, character: col}, end: {line: line, character: col}},
              },
            }
          end,
        }
      end.to_a
      {original: e["original_source"].as_s, steps: steps}
    end
  end
end
