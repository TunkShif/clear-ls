require "./server"
require "./diagnostics"
require "./formatting"
require "../ide/analysis"
require "../ide/semantic_tokens"
require "../ide/completion"
require "../ide/type_info"
require "../ide/signature_help"
require "../ide/navigation"

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
        completionProvider:      {triggerCharacters: [".", ":", "@"], resolveProvider: false},
        inlayHintProvider:       true,
        implementationProvider:  true,
        documentFormattingProvider: true,
        callHierarchyProvider:   true,
        signatureHelpProvider:   {triggerCharacters: ["(", ","], retriggerCharacters: [" "]},
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
      when "textDocument/completion"     then completion(params)
      when "textDocument/inlayHint"      then inlay_hint(params)
      when "textDocument/signatureHelp"  then signature_help(params)
      when "textDocument/implementation" then implementation(params)
      when "textDocument/formatting"     then formatting(params)
      when "textDocument/prepareCallHierarchy" then prepare_call_hierarchy(params)
      when "callHierarchy/outgoingCalls" then outgoing_calls(params)
      when "callHierarchy/incomingCalls" then [] of Nil
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
      sites = type_info(state).method_definitions(off)
      unless sites.empty?
        return sites.compact_map { |s| location_json(IDE::Location.new(s.file, s.item.name_range)) }
      end
      a.definition(off).compact_map { |loc| location_json(loc) }
    end

    private def hover(params : JSON::Any)
      state = document(params)
      off = offset(state, params["position"])
      ti = type_info(state)
      if hit = ti.local_hover(off) || ti.var_hover(off) || ti.self_hover(off) || ti.accessor_macro_hover(off) || ti.def_hover(off) || ti.decl_param_hover(off) || ti.literal_hover(off) || ti.key_or_op_hover(off) || ti.method_hover(off)
        md, r = hit
        return {contents: {kind: "markdown", value: md}, range: range_json(state, r)}
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

    COMPLETION_KINDS = {
      IDE::CompletionKind::Method => 2, IDE::CompletionKind::Function => 3, IDE::CompletionKind::Variable => 6,
      IDE::CompletionKind::Field => 5, IDE::CompletionKind::Class => 7, IDE::CompletionKind::Struct => 22,
      IDE::CompletionKind::Module => 9, IDE::CompletionKind::Enum => 13, IDE::CompletionKind::EnumMember => 20,
      IDE::CompletionKind::Constant => 21, IDE::CompletionKind::Keyword => 14, IDE::CompletionKind::Snippet => 15,
      IDE::CompletionKind::Macro => 3,
    }

    private def completion(params : JSON::Any)
      state = document(params)
      off = offset(state, params["position"])
      items = IDE::Completion.new(state, index, typing).complete(off)
      {
        isIncomplete: items.size >= IDE::Completion::MAX_ITEMS,
        items:        items.map do |i|
          doc = i.documentation.try { |d| {kind: "markdown", value: d} }
          {label: i.label, kind: COMPLETION_KINDS[i.kind], detail: i.detail, documentation: doc,
           sortText: i.sort_text, insertText: i.insert_text}
        end,
      }
    end

    private def navigation(state : FileState) : IDE::Navigation
      IDE::Navigation.new(state, bodies(state), typing, analysis(state))
    end

    private def implementation(params : JSON::Any)
      state = document(params)
      off = offset(state, params["position"])
      navigation(state).implementations(off).compact_map { |s| location_json(IDE::Location.new(s.file, s.item.name_range)) }
    end

    private def prepare_call_hierarchy(params : JSON::Any)
      state = document(params)
      off = offset(state, params["position"])
      nav = navigation(state)
      item = nav.call_item_at(off)
      if item.nil? && (hit = type_info(state).call_at(off))
        # On a call: its resolved targets.
        _, matches, _ = hit
        return matches.first(10).compact_map { |m| call_item_json(IDE::CallItem.new(m.site, m.owner)) }
      end
      item ? [call_item_json(item)].compact : nil
    end

    private def outgoing_calls(params : JSON::Any)
      data = params["item"]["data"]?
      uri = params["item"]["uri"].as_s
      state = @vfs.file?(uri) || @vfs.load(uri) || return [] of Nil
      start = data.try(&.["start"]?.try(&.as_i64.to_u32)) || offset(state, params["item"]["selectionRange"]["start"])
      nav = navigation(state)
      item = nav.call_item_at(start + 1) || return [] of Nil
      nav.outgoing_calls(item).compact_map do |c|
        to = call_item_json(c.target) || next
        {to: to, fromRanges: c.ranges.map { |r| range_json(state, r) }}
      end
    end

    private def call_item_json(item : IDE::CallItem)
      uri = @vfs.uri(item.site.file)
      state = @vfs.file?(uri) || @vfs.load(uri) || return nil
      it = item.site.item
      owner = typing.def_map[item.owner].full_name
      {
        name:           it.name,
        kind:           6, # Method
        detail:         owner.empty? ? it.signature.to_s : "#{owner}#{it.signature.try(&.receiver) ? "." : "#"}#{it.name}#{it.signature}",
        uri:            uri,
        range:          range_json(state, it.range),
        selectionRange: range_json(state, it.name_range),
        data:           {start: it.range.start},
      }
    end

    private def signature_help(params : JSON::Any)
      state = document(params)
      off = offset(state, params["position"])
      res = IDE::SignatureHelp.new(state, typing).help(off) || return nil
      {
        signatures: res.signatures.map do |s|
          {
            label:           s.label,
            documentation:   s.documentation.try { |d| {kind: "markdown", value: d} },
            parameters:      s.parameters.map { |p| {label: [p.label[0], p.label[1]]} },
            activeParameter: s.active_parameter,
          }
        end,
        activeSignature: res.active_signature,
        activeParameter: res.signatures[res.active_signature]?.try(&.active_parameter),
      }
    end

    private def inlay_hint(params : JSON::Any)
      state = document(params)
      r = params["range"]
      range = TextRange.new(offset(state, r["start"]), offset(state, r["end"]))
      type_info(state).inlay_hints(range).map do |h|
        p = state.line_index.position(h.offset, @encoding)
        {position: {line: p.line, character: p.column}, label: h.label, kind: 1, paddingLeft: false}
      end
    end

    # -- helpers --------------------------------------------------------------

    @typing : IDE::Typing? = nil
    @typing_map : Semantics::DefMap? = nil

    # Typing state follows the DefMap: a new map (declarations changed)
    # means a fresh type table and caches.
    private def typing : IDE::Typing
      map = index.def_map
      if (t = @typing) && @typing_map.same?(map)
        return t
      end
      @typing_map = map
      @typing = IDE::Typing.new(map, @vfs)
    end

    private def type_info(state : FileState) : IDE::TypeInfo
      IDE::TypeInfo.new(state, bodies(state), typing)
    end

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
