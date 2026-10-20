require "./server"
require "../ide/analysis"

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
      a.definition(off).compact_map { |loc| location_json(loc) }
    end

    private def hover(params : JSON::Any)
      state = document(params)
      info = analysis(state).hover(offset(state, params["position"])) || return nil
      {contents: {kind: "markdown", value: info.markdown}, range: range_json(state, info.range)}
    end

    private def document_link(params : JSON::Any)
      state = document(params)
      analysis(state).document_links.map do |l|
        {range: range_json(state, l.range), target: VFS.uri_for(l.target)}
      end
    end

    # -- helpers --------------------------------------------------------------

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
