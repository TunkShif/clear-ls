require "./server"
require "../ide/analysis"
require "../ide/semantic_tokens"

module ClearLS::LSP
  # Phase 1 language features: symbols, folding, selection, and
  # declaration-based definition / hover / links.
  class Server
    # LSP SymbolKind values.
    SYMBOL_KINDS = {
      Items::ItemKind::Module     => 2,
      Items::ItemKind::Class      => 5,
      Items::ItemKind::Struct     => 23,
      Items::ItemKind::Enum       => 10,
      Items::ItemKind::Lib        => 3,
      Items::ItemKind::Annotation => 5,
      Items::ItemKind::Alias      => 26,
      Items::ItemKind::TypeDef    => 26,
      Items::ItemKind::CStruct    => 23,
      Items::ItemKind::CUnion     => 23,
      Items::ItemKind::Constant   => 14,
      Items::ItemKind::Def        => 6,
      Items::ItemKind::Macro      => 12,
      Items::ItemKind::Fun        => 12,
      Items::ItemKind::CVar       => 13,
      Items::ItemKind::CField     => 8,
      Items::ItemKind::InstanceVar => 8,
      Items::ItemKind::ClassVar   => 8,
    }

    private def feature_capabilities
      {
        documentSymbolProvider:  true,
        workspaceSymbolProvider: true,
        foldingRangeProvider:    true,
        selectionRangeProvider:  true,
        definitionProvider:      true,
        hoverProvider:           true,
        documentLinkProvider:    {resolveProvider: false},
        documentHighlightProvider: true,
        referencesProvider:      true,
        renameProvider:          {prepareProvider: true},
        semanticTokensProvider:  {
          legend: {
            tokenTypes:     IDE::TokenType.names.map(&.camelcase(lower: true)),
            tokenModifiers: IDE::TokenModifier.names.reject(&.in?("None", "All")).map(&.camelcase(lower: true)),
          },
          full:  true,
          range: true,
        },
      }
    end

    private def feature_request(method : String, params : JSON::Any)
      case method
      when "textDocument/documentSymbol" then document_symbol(params)
      when "workspace/symbol"            then workspace_symbol(params)
      when "textDocument/foldingRange"   then folding_range(params)
      when "textDocument/selectionRange" then selection_range(params)
      when "textDocument/definition"     then definition(params)
      when "textDocument/hover"          then hover(params)
      when "textDocument/documentLink"   then document_link(params)
      when "textDocument/documentHighlight" then document_highlight(params)
      when "textDocument/references"     then references(params)
      when "textDocument/prepareRename"  then prepare_rename(params)
      when "textDocument/rename"         then rename(params)
      when "textDocument/semanticTokens/full"  then semantic_tokens(params, nil)
      when "textDocument/semanticTokens/range" then semantic_tokens(params, params["range"])
      else
        raise ResponseError.new(ErrorCode::MethodNotFound, "unhandled method #{method}")
      end
    end

    # -- handlers -------------------------------------------------------------

    private def document_symbol(params : JSON::Any)
      state = document(params)
      symbols = analysis(state).document_symbols
      JSON.parse(JSON.build { |json| json.array { symbols.each { |s| symbol_json(s, state, json) } } })
    end

    private def symbol_json(s : IDE::SymbolInfo, state : FileState, json : JSON::Builder) : Nil
      json.object do
        json.field "name", s.name
        json.field "detail", s.detail if s.detail
        json.field "kind", SYMBOL_KINDS[s.kind]
        json.field "range" { range_json(state, s.range).to_json(json) }
        json.field "selectionRange" { range_json(state, s.selection_range).to_json(json) }
        json.field "children" { json.array { s.children.each { |c| symbol_json(c, state, json) } } }
      end
    end

    private def workspace_symbol(params : JSON::Any)
      query = params["query"]?.try(&.as_s) || ""
      IDE::Analysis.workspace_symbols(index, query, index.project.root).compact_map do |s|
        loc = location_json(s.location) || next
        {name: s.name, kind: SYMBOL_KINDS[s.kind], containerName: s.container, location: loc}
      end
    end

    private def folding_range(params : JSON::Any)
      analysis(document(params)).folding_ranges.map do |f|
        f.comment ? {startLine: f.start_line, endLine: f.end_line, kind: "comment"} : {startLine: f.start_line, endLine: f.end_line, kind: nil}
      end
    end

    private def selection_range(params : JSON::Any)
      state = document(params)
      a = analysis(state)
      params["positions"].as_a.map do |pos|
        ranges = a.selection_ranges(offset(state, pos))
        # Build the linked list outermost-first.
        result = nil.as(JSON::Any?)
        ranges.reverse_each do |r|
          obj = {"range" => JSON.parse(range_json(state, r).to_json)} of String => JSON::Any
          obj["parent"] = result if result
          result = JSON::Any.new(obj)
        end
        result || JSON.parse({range: range_json(state, TextRange.empty(offset(state, pos)))}.to_json)
      end
    end

    private def definition(params : JSON::Any)
      state = document(params)
      off = offset(state, params["position"])
      a = analysis(state)
      if path = a.require_definition(off)
        return [{uri: VFS.uri_for(path), range: {start: {line: 0, character: 0}, end: {line: 0, character: 0}}}]
      end
      if r = locals(state).definition(off)
        return [{uri: state.uri, range: range_json(state, r)}]
      end
      a.definition(off).compact_map { |loc| location_json(loc) }
    end

    private def hover(params : JSON::Any)
      state = document(params)
      off = offset(state, params["position"])
      if hit = locals(state).binding_at(off)
        _, b, r = hit
        md = "```crystal\n#{b.name}#{b.restriction ? " : #{b.restriction}" : ""}\n```\n\n#{LOCAL_KINDS[b.kind]}"
        return {contents: {kind: "markdown", value: md}, range: range_json(state, r.range)}
      end
      info = analysis(state).hover(off) || return nil
      {contents: {kind: "markdown", value: info.markdown}, range: range_json(state, info.range)}
    end

    private def document_link(params : JSON::Any)
      state = document(params)
      analysis(state).document_links.map do |l|
        {range: range_json(state, l.range), target: VFS.uri_for(l.target)}
      end
    end

    LOCAL_KINDS = {
      HIR::BindingKind::Param      => "parameter",
      HIR::BindingKind::BlockParam => "block parameter",
      HIR::BindingKind::BlockArg   => "block argument",
      HIR::BindingKind::Local      => "local variable",
      HIR::BindingKind::RescueVar  => "rescued exception",
      HIR::BindingKind::TypeDecl   => "local variable",
      HIR::BindingKind::MacroVar   => "macro variable",
    }

    # DocumentHighlightKind: 2 read, 3 write.
    private def document_highlight(params : JSON::Any)
      state = document(params)
      locals(state).highlights(offset(state, params["position"])).map do |r|
        {range: range_json(state, r.range), kind: r.kind.read? ? 2 : 3}
      end
    end

    # Locals only in Phase 2: other symbols return an empty list rather than
    # guessing by name.
    private def references(params : JSON::Any)
      state = document(params)
      include_decl = params.dig?("context", "includeDeclaration").try(&.as_bool) != false
      locals(state).references(offset(state, params["position"]), include_decl).map do |r|
        {uri: state.uri, range: range_json(state, r.range)}
      end
    end

    private def prepare_rename(params : JSON::Any)
      state = document(params)
      r, name = locals(state).prepare_rename(offset(state, params["position"])) ||
                raise ResponseError.new(ErrorCode::InvalidRequest, "only local variables can be renamed yet")
      {range: range_json(state, r), placeholder: name}
    end

    private def rename(params : JSON::Any)
      state = document(params)
      new_name = params["newName"].as_s
      unless IDE::Locals.valid_local?(new_name)
        raise ResponseError.new(ErrorCode::InvalidParams, "#{new_name.inspect} is not a valid local variable name")
      end
      edits = locals(state).rename(offset(state, params["position"]), new_name) ||
              raise ResponseError.new(ErrorCode::InvalidRequest, "cannot rename this symbol")
      {changes: {state.uri => edits.map { |(r, t)| {range: range_json(state, r), newText: t} }}}
    end

    private def semantic_tokens(params : JSON::Any, range : JSON::Any?)
      state = document(params)
      byte_range = range.try do |r|
        TextRange.new(offset(state, r["start"]), offset(state, r["end"]))
      end
      stdlib = index.project.stdlib_dir
      is_std = ->(f : FileId) { !!stdlib && (VFS.path_for(@vfs.uri(f)) || "").starts_with?(stdlib.not_nil!) }
      tokens = IDE::SemanticTokens.new(state, bodies(state), index.def_map, is_std).tokens(byte_range)
      {data: IDE::SemanticTokens.encode(tokens, state.line_index, @encoding)}
    end

    # -- helpers --------------------------------------------------------------

    @body_cache = IDE::BodyCache.new

    private def bodies(state : FileState) : IDE::Bodies
      @body_cache.for(state)
    end

    private def evict_bodies(id : FileId) : Nil
      @body_cache.evict(id)
    end

    private def locals(state : FileState) : IDE::Locals
      IDE::Locals.new(state, bodies(state))
    end

    private def analysis(state : FileState) : IDE::Analysis
      IDE::Analysis.new(state, index)
    end

    private def document(params : JSON::Any) : FileState
      uri = params.dig("textDocument", "uri").as_s
      @vfs.file?(uri) || @vfs.load(uri) ||
        raise ResponseError.new(ErrorCode::InvalidParams, "unknown document #{uri}")
    end

    private def offset(state : FileState, pos : JSON::Any) : UInt32
      state.line_index.offset(position(pos), @encoding)
    end

    private def range_json(state : FileState, r : TextRange)
      range_json(state.line_index, r)
    end

    private def range_json(index : LineIndex, r : TextRange)
      a = index.position(r.start, @encoding)
      b = index.position(r.end, @encoding)
      {start: {line: a.line, character: a.column}, end: {line: b.line, character: b.column}}
    end

    # Converts using the target file's text: open buffer, else disk.
    private def location_json(loc : IDE::Location)
      index = @vfs.line_index_for(loc.file) || return nil
      {uri: @vfs.uri(loc.file), range: range_json(index, loc.range)}
    end
  end
end
