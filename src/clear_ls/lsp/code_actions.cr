require "./features"

module ClearLS::LSP
  # `textDocument/codeAction` (quick fixes for compiler diagnostics).
  #
  # Works from the diagnostics the client sends back (`context.diagnostics`,
  # published by `diagnostics.cr`), so every action answers an actual
  # compiler error:
  #
  # - "Did you mean 'x'?" in the message: replace the diagnostic's range
  #   with the compiler's suggestion.
  # - `undefined constant Foo` where a workspace file of the same program
  #   declares `Foo` at the top level: add `require "./relative/path"`
  #   after the file's last top-level require (or at the top).
  class Server
    private def code_action(params : JSON::Any)
      state = document(params)
      diags = params.dig?("context", "diagnostics").try(&.as_a?) || [] of JSON::Any
      actions = [] of JSON::Any
      diags.each do |d|
        next unless d["source"]?.try(&.as_s?) == "crystal"
        message = d["message"]?.try(&.as_s?) || next
        if m = message.match(/Did you mean '([^']+)'\?/)
          actions << quick_fix("Replace with '#{m[1]}'", d, state.uri, d["range"], m[1], preferred: true)
        end
        if m = message.match(/\Aundefined constant ([A-Z][\w:]*)/)
          require_actions(state, m[1]).each { |a| actions << a.merge_diagnostic(d) }
        end
      end
      actions
    end

    private def quick_fix(title : String, diag : JSON::Any, uri : String, range : JSON::Any, text : String, preferred = false) : JSON::Any
      JSON.parse({
        title:       title,
        kind:        "quickfix",
        diagnostics: [diag],
        isPreferred: preferred,
        edit:        {changes: {uri => [{range: range, newText: text}]}},
      }.to_json)
    end

    # `require` edits for workspace files whose top-level declarations
    # include *name* (first path segment). Files already required, the
    # file itself, and library files are skipped.
    private def require_actions(state : FileState, name : String) : Array(RequireAction)
      head = name.split("::").first
      path = VFS.path_for(state.uri) || return [] of RequireAction
      dir = File.dirname(path)
      required = index.entry?(state.id).try(&.requires) || [] of String
      found = [] of RequireAction
      index.files_with_word(head).each do |file|
        next if file == state.id || index.library_file?(file)
        entry = index.entry?(file) || next
        next if required.includes?(entry.path)
        next unless entry.items.items.any? { |i| (i.kind.namespace? || i.kind.alias? || i.kind.constant?) && (i.header.try(&.path.first?) || i.name) == head }
        rel = Path[entry.path].relative_to(dir).to_s.rchop(".cr")
        rel = "./#{rel}" unless rel.starts_with?('.')
        found << RequireAction.new(%(Add require "#{rel}"), state.uri, require_insert(state), %(require "#{rel}"\n))
      end
      found.sort_by(&.title).first(5)
    end

    # After the last top-level `require`, else line 0.
    private def require_insert(state : FileState) : JSON::Any
      line = 0_u32
      state.tree.root.named_children.each do |n|
        line = state.line_index.position(n.end_byte, @encoding).line + 1 if n.kind.require?
      end
      JSON.parse({start: {line: line, character: 0}, end: {line: line, character: 0}}.to_json)
    end

    record RequireAction, title : String, uri : String, range : JSON::Any, text : String do
      def merge_diagnostic(d : JSON::Any) : JSON::Any
        JSON.parse({
          title:       title,
          kind:        "quickfix",
          diagnostics: [d],
          edit:        {changes: {uri => [{range: range, newText: text}]}},
        }.to_json)
      end
    end
  end
end
