require "./server"
require "./diagnostics"
require "./formatting"
require "./expand"
require "./context"
require "./warmup"
require "../ide/analysis"
require "../ide/semantic_tokens"
require "../ide/completion"
require "../ide/type_info"
require "../ide/signature_help"
require "../ide/navigation"
require "../ide/references"

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
        typeHierarchyProvider:   true,
        codeActionProvider:      {codeActionKinds: ["quickfix"]},
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
      when "callHierarchy/incomingCalls" then incoming_calls(params)
      when "textDocument/prepareTypeHierarchy" then prepare_type_hierarchy(params)
      when "textDocument/codeAction"     then code_action(params)
      when "typeHierarchy/supertypes"    then type_hierarchy(params, super: true)
      when "typeHierarchy/subtypes"      then type_hierarchy(params, super: false)
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
      paths = a.require_definitions(off)
      unless paths.empty?
        return paths.map { |path| {uri: VFS.uri_for(path), range: {start: {line: 0, character: 0}, end: {line: 0, character: 0}}} }
      end
      if r = locals(state).definition(off)
        return [{uri: state.uri, range: range_json(state, r)}]
      end
      ivars = type_info(state).ivar_definitions(off)
      unless ivars.empty?
        return ivars.compact_map { |s| location_json(IDE::Location.new(s.file, s.item.name_range)) }
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
      # The name in `property name = "x"` lowers to a class-body local:
      # the accessor wins.
      if hit = ti.accessor_macro_hover(off)
        md, r = hit
        return {contents: {kind: "markdown", value: md}, range: range_json(state, r)}
      end
      if hit = ti.local_hover(off)
        md, r = hit
        md = add_compiler_type(state, off, md)
        return {contents: {kind: "markdown", value: md}, range: range_json(state, r)}
      end
      if hit = ti.var_hover(off) || ti.self_hover(off) || ti.def_hover(off) || ti.decl_param_hover(off) || ti.literal_hover(off) || ti.key_or_op_hover(off) || ti.method_hover(off)
        md, r = hit
        return {contents: {kind: "markdown", value: md}, range: range_json(state, r)}
      end
      info = analysis(state).hover(off) || return nil
      {contents: {kind: "markdown", value: info.markdown}, range: range_json(state, info.range)}
    end

    # Appends the compiler's types for the local under the cursor, when a
    # context run for its def has finished.
    private def add_compiler_type(state : FileState, off : UInt32, md : String) : String
      body, b, _ = locals(state).binding_at(off) || return md
      types = compiler_types(state, body, b.name) || return md
      md + "\n\ncompiler: " + types.map { |t| "`#{t}`" }.join(" · ")
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

    # Locals by binding; methods, types and constants across the
    # workspace by identity (`IDE::References`). Possible references
    # (same name, unknown identity) only with
    # `initializationOptions.references.includePossible`.
    private def references(params : JSON::Any)
      state = document(params)
      off = offset(state, params["position"])
      include_decl = params.dig?("context", "includeDeclaration").try(&.as_bool) != false
      local = def_name_at?(state, off) ? [] of HIR::Reference : locals(state).references(off, include_decl)
      unless local.empty?
        return local.map { |r| {uri: state.uri, range: range_json(state, r.range)} }
      end
      refs = workspace_references(state, off) || return [] of Nil
      refs.compact_map do |r|
        next if r.declaration && !include_decl
        next unless r.exact || include_possible?
        location_json(IDE::Location.new(r.file, r.range))
      end
    end

    private def include_possible? : Bool
      @settings.bool("references.includePossible")
    end

    private def workspace_references(state : FileState, off : UInt32) : Array(IDE::Reference)?
      finder = references_finder
      ctx = IDE::References::Context.new(state, bodies(state), typing(state))
      target = finder.target_at(ctx, off) || return nil
      Job.read(state.id)
      begin
        finder.find(target, state.id)
      rescue ex : IDE::CandidateLimit
        raise ResponseError.new(ErrorCode::RequestFailed, ex.message || "too many candidate files")
      end
    end

    private def references_finder : IDE::References
      root = index.project.root
      IDE::References.new(index, ->(file : FileId) do
        uri = @vfs.uri(file)
        st = @vfs.file?(uri) || @vfs.load(uri)
        st.try { |x| IDE::References::Context.new(x, bodies(x), typing(x)) }
      end, ->(r : IDE::Reference) do
        path = VFS.path_for(@vfs.uri(r.file)) || @vfs.uri(r.file)
        line = @vfs.line_index_for(r.file).try { |li| li.position(r.range.start, PositionEncoding::UTF8).line + 1 }
        "#{Path[path].relative_to(root)}:#{line}"
      end, ->(progress : String, file : FileId?) do
        if job = Job.current
          job.progress = progress unless progress.empty?
          file.try { |f| job.read(f) }
          job.checkpoint
        end
        nil
      end).tap do |f|
        f.max_candidates = @settings.int("budgets.maxCandidates").to_i
      end
    end

    private def prepare_rename(params : JSON::Any)
      state = document(params)
      off = offset(state, params["position"])
      if !def_name_at?(state, off) && (hit = locals(state).prepare_rename(off))
        r, name = hit
        return {range: range_json(state, r), placeholder: name}
      end
      plan = rename_plan(state, off, nil, search: false)
      if err = plan.error
        raise ResponseError.new(ErrorCode::InvalidRequest, err)
      end
      r = plan.range || raise ResponseError.new(ErrorCode::InvalidRequest, "nothing to rename here")
      {range: range_json(state, r), placeholder: state.text.byte_slice(r.start, r.size)}
    end

    private def rename(params : JSON::Any)
      state = document(params)
      off = offset(state, params["position"])
      new_name = params["newName"].as_s
      if !def_name_at?(state, off) && locals(state).prepare_rename(off)
        unless IDE::Locals.valid_local?(new_name)
          raise ResponseError.new(ErrorCode::InvalidParams, "#{new_name.inspect} is not a valid local variable name")
        end
        edits = locals(state).rename(off, new_name) ||
                raise ResponseError.new(ErrorCode::InvalidRequest, "cannot rename this symbol")
        return {changes: {state.uri => edits.map { |(r, t)| {range: range_json(state, r), newText: t} }}}
      end
      plan = rename_plan(state, off, new_name)
      if err = plan.error
        raise ResponseError.new(ErrorCode::InvalidRequest, err)
      end
      changes = {} of String => Array(NamedTuple(range: NamedTuple(start: NamedTuple(line: UInt32, character: UInt32), end: NamedTuple(line: UInt32, character: UInt32)), newText: String))
      plan.edits.not_nil!.each do |r|
        loc = location_json(IDE::Location.new(r.file, r.range)) || next
        (changes[loc[:uri]] ||= [] of NamedTuple(range: NamedTuple(start: NamedTuple(line: UInt32, character: UInt32), end: NamedTuple(line: UInt32, character: UInt32)), newText: String)) << {range: loc[:range], newText: new_name}
      end
      {changes: changes}
    end

    private def def_name_at?(state : FileState, off : UInt32) : Bool
      references_finder.def_name_at?(IDE::References::Context.new(state, bodies(state), typing(state)), off)
    end

    private def rename_plan(state : FileState, off : UInt32, new_name : String?, search = true) : IDE::References::RenamePlan
      ctx = IDE::References::Context.new(state, bodies(state), typing(state))
      Job.read(state.id)
      references_finder.rename_plan(ctx, off, new_name, search)
    rescue ex : IDE::CandidateLimit
      raise ResponseError.new(ErrorCode::RequestFailed, ex.message || "too many candidate files")
    end

    private def semantic_tokens(params : JSON::Any, range : JSON::Any?)
      state = document(params)
      byte_range = range.try do |r|
        TextRange.new(offset(state, r["start"]), offset(state, r["end"]))
      end
      stdlib = index.project.stdlib_dir
      is_std = ->(f : FileId) { !!stdlib && (VFS.path_for(@vfs.uri(f)) || "").starts_with?(stdlib.not_nil!) }
      tokens = IDE::SemanticTokens.new(state, bodies(state), index.def_map_for(state.id), is_std).tokens(byte_range)
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
      opts = IDE::CompletionOptions.new(snippets: snippet_support?, setter_snippets: @settings.bool("completion.setterSnippets"),
        block_snippets: @settings.bool("completion.blockSnippets"), block_style: @settings.string?("completion.blockStyle") || "braces")
      items = IDE::Completion.new(state, index, typing(state), opts).complete(off)
      {
        isIncomplete: items.size >= IDE::Completion::MAX_ITEMS,
        items:        items.map { |i| completion_item_json(state, i) },
      }
    end

    # Optional fields are omitted, not `null`: clients index them
    # (Neovim's `vim.lsp.completion` fails on `"textEdit": null`).
    private def completion_item_json(state : FileState, i : IDE::CompletionItem) : JSON::Any
      h = {"label" => JSON::Any.new(i.label), "kind" => JSON::Any.new(COMPLETION_KINDS[i.kind].to_i64)} of String => JSON::Any
      i.detail.try { |d| h["detail"] = JSON::Any.new(d) }
      i.documentation.try { |d| h["documentation"] = JSON.parse({kind: "markdown", value: d}.to_json) }
      i.sort_text.try { |t| h["sortText"] = JSON::Any.new(t) }
      i.filter_text.try { |t| h["filterText"] = JSON::Any.new(t) }
      if r = i.edit_range
        h["textEdit"] = JSON.parse({range: range_json(state, r), newText: i.insert_text || i.label}.to_json)
      elsif t = i.insert_text
        h["insertText"] = JSON::Any.new(t)
      end
      h["insertTextFormat"] = JSON::Any.new(2_i64) if i.snippet
      JSON::Any.new(h)
    end

    private def snippet_support? : Bool
      @client_capabilities.dig?("textDocument", "completion", "completionItem", "snippetSupport").try(&.as_bool?) || false
    end

    private def navigation(state : FileState) : IDE::Navigation
      IDE::Navigation.new(state, bodies(state), typing(state), analysis(state))
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
        map = index.def_map_for(state.id)
        return matches.first(10).compact_map { |m| call_item_json(IDE::CallItem.new(m.site, m.owner), map) }
      end
      item ? [call_item_json(item, index.def_map_for(state.id))].compact : nil
    end

    private def outgoing_calls(params : JSON::Any)
      data = params["item"]["data"]?
      uri = params["item"]["uri"].as_s
      state = @vfs.file?(uri) || @vfs.load(uri) || return [] of Nil
      start = data.try(&.["start"]?.try(&.as_i64.to_u32)) || offset(state, params["item"]["selectionRange"]["start"])
      nav = navigation(state)
      item = nav.call_item_at(start + 1) || return [] of Nil
      nav.outgoing_calls(item).compact_map do |c|
        to = call_item_json(c.target, index.def_map_for(state.id)) || next
        {to: to, fromRanges: c.ranges.map { |r| range_json(state, r) }}
      end
    end

    # Callers of the def in *item*: exact references grouped by the def
    # (or file body) that contains them.
    private def incoming_calls(params : JSON::Any)
      data = params["item"]["data"]?
      uri = params["item"]["uri"].as_s
      state = @vfs.file?(uri) || @vfs.load(uri) || return [] of Nil
      start = data.try(&.["start"]?.try(&.as_i64.to_u32)) || offset(state, params["item"]["selectionRange"]["start"])
      item = navigation(state).call_item_at(start + 1) || return [] of Nil
      finder = references_finder
      target = IDE::MethodTarget.new(item.site.item.name, [item.site], item.owner)
      groups = {} of {FileId, UInt32} => {IDE::CallItem?, FileState, Array(TextRange)}
      Job.read(state.id)
      refs = begin
        finder.find(target, state.id)
      rescue ex : IDE::CandidateLimit
        raise ResponseError.new(ErrorCode::RequestFailed, ex.message || "too many candidate files")
      end
      refs.each do |r|
        next if r.declaration || !r.exact
        st = @vfs.file?(@vfs.uri(r.file)) || @vfs.load(@vfs.uri(r.file)) || next
        caller = navigation(st).call_item_at(r.range.start)
        key = {r.file, caller.try(&.site.item.range.start) || 0_u32}
        g = groups[key] ||= {caller, st, [] of TextRange}
        g[2] << r.range
      end
      groups.values.compact_map do |(caller, st, ranges)|
        from = if caller
                 call_item_json(caller, index.def_map_for(st.id))
               else
                 file_item_json(st)
               end
        from || next
        {from: from, fromRanges: ranges.map { |r| range_json(st, r) }}
      end
    end

    # Top-level code of a file as a call hierarchy item.
    private def file_item_json(state : FileState)
      path = VFS.path_for(state.uri) || state.uri
      {
        name:           File.basename(path),
        kind:           1, # File
        detail:         "top level",
        uri:            state.uri,
        range:          range_json(state, TextRange.new(0_u32, state.text.bytesize.to_u32)),
        selectionRange: range_json(state, TextRange.new(0_u32, 0_u32)),
        data:           {start: -1},
      }
    end

    # -- type hierarchy -----------------------------------------------------------

    private def prepare_type_hierarchy(params : JSON::Any)
      state = document(params)
      off = offset(state, params["position"])
      target = references_finder.target_at(IDE::References::Context.new(state, bodies(state), typing(state)), off)
      return nil unless target.is_a?(IDE::PathTarget) && target.type?
      map = index.def_map_for(state.id)
      id = map.lookup_path("::" + target.full_name) || return nil
      [type_item_json(map, id, state.id)].compact
    end

    private def type_hierarchy(params : JSON::Any, super is_super : Bool)
      data = params["item"]["data"]
      file = FileId.new(data["file"].as_i.to_u32)
      map = index.def_map_for(file)
      id = map.lookup_path("::" + data["name"].as_s) || return [] of Nil
      related = if is_super
                  (map.includes(id) + [map.superclass(id)].compact).uniq
                else
                  map.subtypes(id)
                end
      related.compact_map { |t| type_item_json(map, t, file) }
    end

    TYPE_SYMBOL_KINDS = {
      Semantics::TypeKind::Module => 2, Semantics::TypeKind::Class => 5, Semantics::TypeKind::Struct => 23,
      Semantics::TypeKind::Enum => 10, Semantics::TypeKind::Lib => 3, Semantics::TypeKind::Annotation => 5,
      Semantics::TypeKind::CStruct => 23, Semantics::TypeKind::CUnion => 23,
    }

    # *view_file*: a file of the program the type is seen from (items of
    # one hierarchy all come from that view's DefMap).
    private def type_item_json(map : Semantics::DefMap, id : Semantics::TypeId, view_file : FileId)
      info = map[id]
      site = info.sites.first? || return nil
      loc = location_json(IDE::Location.new(site.file, site.item.name_range)) || return nil
      whole = location_json(IDE::Location.new(site.file, site.item.range)) || return nil
      {
        name:           info.full_name,
        kind:           TYPE_SYMBOL_KINDS[info.kind]? || 5,
        detail:         info.sites.size > 1 ? "#{info.sites.size} declarations" : nil,
        uri:            loc[:uri],
        range:          whole[:range],
        selectionRange: loc[:range],
        data:           {name: info.full_name, file: view_file.value},
      }
    end

    # *map*: the DefMap the item's owner TypeId comes from.
    private def call_item_json(item : IDE::CallItem, map : Semantics::DefMap)
      uri = @vfs.uri(item.site.file)
      state = @vfs.file?(uri) || @vfs.load(uri) || return nil
      it = item.site.item
      owner = map[item.owner].full_name
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
      res = IDE::SignatureHelp.new(state, typing(state)).help(off) || return nil
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
      return [] of Nil unless @settings.bool("inlayHints.enabled")
      kinds = IDE::InlayHintKinds.new(@settings.bool("inlayHints.locals"), @settings.bool("inlayHints.blockParams"),
        @settings.bool("inlayHints.returnTypes"), @settings.bool("inlayHints.aliases"))
      type_info(state).inlay_hints(range, kinds).map do |h|
        p = state.line_index.position(h.offset, @encoding)
        {position: {line: p.line, character: p.column}, label: h.label, kind: 1, paddingLeft: false}
      end
    end

    # -- helpers --------------------------------------------------------------

    # Typing state per DefMap (one per program view): a new map
    # (declarations changed) means a fresh type table and caches.
    @typings = {} of UInt64 => {Semantics::DefMap, IDE::Typing}

    private def typing(file : FileId) : IDE::Typing
      map = index.def_map_for(file)
      key = map.object_id
      if (t = @typings[key]?) && t[0].same?(map)
        return t[1]
      end
      # Drop typings of maps no view uses any more (declarations changed).
      # Live views keep theirs: a references search walks many views, and
      # evicting by count threw their summary caches away every search.
      @typings.reject! { |_, (m, _)| !index.live_map?(m) }
      @typings[key] = {map, IDE::Typing.new(map, @vfs)}
      @typings[key][1]
    end

    private def typing(state : FileState) : IDE::Typing
      typing(state.id)
    end

    private def type_info(state : FileState) : IDE::TypeInfo
      IDE::TypeInfo.new(state, bodies(state), typing(state)).tap { |t| t.aliases = @settings.bool("inlayHints.aliases") }
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
      IDE::Analysis.new(state, index, index.def_map_for(state.id))
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
