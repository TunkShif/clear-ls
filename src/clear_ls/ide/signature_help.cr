require "./typing"
require "./call_context"

module ClearLS::IDE
  record ParameterInfo, label : {Int32, Int32}, documentation : String?

  record SignatureInfo,
    label : String,
    documentation : String?,
    parameters : Array(ParameterInfo),
    active_parameter : Int32?

  record SignatureHelpResult, signatures : Array(SignatureInfo), active_signature : Int32

  # Signature help for the call around the cursor.
  #
  # The call is found textually (`CallContext`), then a patched copy of the
  # buffer is analysed: an empty active argument gets a placeholder and an
  # unclosed call a `)`, so `io.gets(1, |` parses as `io.gets(1, __cl__)`.
  # Signatures are the call's viable overloads first (the placeholder has
  # an unknown type and eliminates nothing), then the rest of the family.
  class SignatureHelp
    PLACEHOLDER = "__cl__"
    MAX_SIGNATURES = 12

    def initialize(@state : FileState, @typing : Typing)
    end

    def help(offset : UInt32) : SignatureHelpResult?
      text = @state.text
      ctx = CallContext.find(text, offset) || return nil
      call, inf = analyse(text, offset, ctx) || return nil
      res = inf.resolutions[call.id]? || inf.resolve_call(call)
      viable = res.matches
      rest = res.family.reject { |m| viable.any? { |v| same_site?(v, m) } }
      ordered = (viable + rest).uniq { |m| {m.site.file, m.site.item.range.start} }.first(MAX_SIGNATURES)
      return nil if ordered.empty?
      sigs = ordered.map { |m| signature_info(m, ctx) }
      SignatureHelpResult.new(sigs, 0)
    end

    # Viable overloads of the call around *offset*, or the whole family when
    # none fits; nil outside calls.
    def viable_matches(offset : UInt32) : Array(Types::MethodMatch)?
      ctx = CallContext.find(@state.text, offset) || return nil
      call, inf = analyse(@state.text, offset, ctx) || return nil
      res = inf.resolutions[call.id]? || inf.resolve_call(call)
      res.candidates.empty? ? res.family : res.matches
    end

    private def same_site?(a : Types::MethodMatch, b : Types::MethodMatch) : Bool
      a.site.file == b.site.file && a.site.item.range == b.site.item.range
    end

    # Parses the patched buffer and finds the call whose `(` is ctx's.
    private def analyse(text : String, offset : UInt32, ctx : CallContext) : {HIR::Expr, Types::Infer}?
      arg_start = text.byte_slice(ctx.open_paren + 1, offset - ctx.open_paren - 1)
      current = arg_start.split(',').last? || ""
      insert = ""
      # A partial word (`li|`) would become a positional argument and change
      # the binding: replace it by the placeholder too.
      word = current[/[a-z_]\w*\z/]?
      if word && current.strip == word
        offset -= word.bytesize
        current = current.rchop(word)
      end
      insert += PLACEHOLDER if current.strip.empty? || current.rstrip.ends_with?(':')
      insert += ")" unless closed_on_line?(text, offset)
      tail_from = offset + (word && current.strip.empty? ? word.bytesize : 0)
      patched = text.byte_slice(0, offset) + insert + text.byte_slice(tail_from, text.bytesize - tail_from)
      tree = Syntax::Parser.new.parse(patched)
      state = FileState.new(@state.id, @state.uri, @state.revision ^ 0x4000_0000_0000_0000_u64, @state.version, tree)
      bodies = Bodies.new(state)
      body, inf = @typing.infer_at(state, bodies, ctx.open_paren, cache: false) || return nil
      call = body.exprs.find { |e| e.kind.call? && e.name_range.try(&.start) == ctx.name_start } || return nil
      {call, inf}
    end

    # Does the rest of the line close the call's `(`?
    private def closed_on_line?(text : String, offset : UInt32) : Bool
      depth = 1
      i = offset
      while i < text.bytesize
        c = text.byte_at(i).unsafe_chr
        break if c == '\n'
        depth += 1 if c == '('
        depth -= 1 if c == ')'
        return true if depth == 0
        i += 1
      end
      false
    end

    private def signature_info(m : Types::MethodMatch, ctx : CallContext) : SignatureInfo
      item = m.site.item
      sig = item.signature
      params = [] of ParameterInfo
      label = String.build do |io|
        io << item.name << '('
        sig.try &.params.each_with_index do |p, i|
          io << ", " if i > 0
          # Offsets in UTF-16 code units (the default LSP encoding for
          # parameter label offsets); labels are ASCII in practice.
          start = io.bytesize
          p.to_s(io)
          params << ParameterInfo.new({start, io.bytesize}, nil)
        end
        # `fun printf(fmt : Char*, ...)`: C variadic arguments.
        if sig.try(&.variadic)
          io << ", " unless sig.try(&.params.empty?)
          io << "..."
        end
        io << ')'
        if (rt = sig.try(&.return_type))
          io << " : " << rt
        end
      end
      SignatureInfo.new(label, item.doc, params, sig.try { |s| active_param(s, ctx) })
    end

    # Parameter the active argument binds to: by name, else by position
    # (extra positionals go to the splat).
    private def active_param(sig : Items::Signature, ctx : CallContext) : Int32?
      ps = sig.params
      if n = ctx.named
        return ps.index { |p| p.kind.positional? && p.call_name == n } || ps.index(&.kind.double_splat?)
      end
      splat = ps.index(&.kind.splat?)
      positional = ps.each_index.select { |i| ps[i].kind.positional? && (splat.nil? || i < splat) }.to_a
      # Positional params already given by name are skipped.
      positional.reject! { |i| ctx.given_names.includes?(ps[i].call_name) }
      positional[ctx.arg_index]? || splat
    end
  end
end
