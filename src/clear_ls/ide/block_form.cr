require "../vfs"

module ClearLS::IDE
  # `{ ... }` ↔ `do ... end` for the block under the cursor (Phase 12,
  # F5): a refactoring code action.
  #
  # Precedence differs: `foo bar do ... end` passes the block to `foo`,
  # `foo bar { ... }` to `bar`. A conversion is refused when it would
  # move the block to another call: braces → do when the block's call is
  # itself an argument of a call written without parentheses, and do →
  # braces when its call's unparenthesized last argument is a call or a
  # bare name (`foo bar do`: `{` would go to `bar`).
  module BlockForm
    record Edit, range : TextRange, text : String, title : String

    # The conversion for the innermost literal block containing *offset*
    # (or nil, with the reason in *why* when one exists but can't be
    # converted).
    def self.convert(state : FileState, offset : UInt32) : Edit | String | Nil
      node = state.tree.root.descendant(offset, offset)
      blk = nil.as(Syntax::Node?)
      while n = node
        # A call's block, or a proc literal's body (`-> { }` / `-> do end`).
        if n.kind.block? && (call = n.parent) && call.field(Syntax::Field::Block) == n
          blk = n
          break
        end
        node = n.parent
      end
      blk = blk || return nil
      call = blk.parent.not_nil!
      is_proc = call.kind.proc_node?
      text = state.text
      src = text.byte_slice(blk.start_byte, blk.end_byte - blk.start_byte)
      braces = src.starts_with?('{')
      return "the block has a syntax error" if blk.has_error?
      # `record Foo do def x; end end`, `Struct.new do ... end`-style bodies
      # with declarations are macro bodies, not blocks `{ }` can hold.
      if !braces && declarations?(blk)
        return "the block declares methods or types (a macro body); `{ }` can't hold it"
      end
      if !braces && blk.named_children.any? { |c| c.kind.rescue? || c.kind.ensure? || c.kind.else? }
        return "the block has `rescue`/`else`/`ensure`, which `{ }` can't hold"
      end
      if braces && !is_proc
        if (outer = enclosing_unparenthesized_call(call))
          return "`do ... end` would pass the block to `#{outer.field_text(Syntax::Field::Method)}` instead"
        end
      elsif !braces && !is_proc
        if unparenthesized_args?(call, text)
          return "`{ }` would bind to the last argument instead of `#{call.field_text(Syntax::Field::Method)}`"
        end
      end
      params = blk.field(Syntax::Field::Params)
      pipes = params ? param_text(text, blk, params) : nil
      body = blk.field(Syntax::Field::Body)
      body_text = inner_text(text, blk, params, braces)
      line_start = line_start(text, call.start_byte)
      indent = text.byte_slice(line_start, call.start_byte - line_start)[/\A[ \t]*/]
      if braces
        # `{ |x| a; b }` → do |x|\n  a\n  b\nend. Statements split at
        # `;` only when the body is one line of simple statements.
        inner = if body_text.includes?('\n') || body_text.includes?('#') || !top_level_semicolons?(body)
                  reindent(body_text, indent + "  ")
                else
                  "#{indent}  #{body_text.gsub(/;\s*/, "\n#{indent}  ")}"
                end
        result = String.build do |io|
          io << "do"
          io << ' ' << pipes if pipes
          io << '\n' << inner unless body_text.empty?
          io << '\n' << indent << "end"
        end
        Edit.new(blk.range, result, "Convert to do ... end")
      else
        lines = body_text.lines.map(&.strip).reject(&.empty?)
        # One line only for a single statement without comments (a `#`
        # would swallow the closing `}`).
        one_line = lines.size <= 1 && !body_text.includes?('#')
        result = if one_line
                "{ #{pipes ? "#{pipes} " : ""}#{lines.first? || ""}#{lines.empty? ? "" : " "}}"
              else
                String.build do |io|
                  io << '{'
                  io << ' ' << pipes if pipes
                  io << '\n' << reindent(body_text, indent + "  ") << '\n' << indent << '}'
                end
              end
        result = result.sub("{  }", "{ }")
        Edit.new(blk.range, result, "Convert to { ... }")
      end
    end

    # Everything between the opening (`{`/`do` and the params) and the
    # closing token, comments included, trimmed.
    private def self.inner_text(text : String, blk : Syntax::Node, params : Syntax::Node?, braces : Bool) : String
      start = if params
                (text.byte_index('|', params.end_byte.to_i) || params.end_byte.to_i) + 1
              else
                blk.start_byte.to_i + (braces ? 1 : 2)
              end
      stop = blk.end_byte.to_i - (braces ? 1 : 3)
      return "" if stop <= start
      text.byte_slice(start, stop - start).strip
    end

    private def self.declarations?(blk : Syntax::Node) : Bool
      body = blk.field(Syntax::Field::Body) || return false
      body.named_children.any? do |c|
        c.kind.method_def? || c.kind.class_def? || c.kind.struct_def? || c.kind.module_def? ||
          c.kind.macro_def? || c.kind.enum_def? || c.kind.alias_node?
      end
    end

    private def self.body_has_comment?(body : Syntax::Node?) : Bool
      return false unless body
      found = false
      body.walk { |n| found = true if n.kind.comment?; !found }
      found
    end

    # Every `;` of a one-line body separates its top-level statements
    # (not inside a string, a nested block, ...).
    private def self.top_level_semicolons?(body : Syntax::Node?) : Bool
      return true unless body
      text = body.text
      count = text.count(';')
      return true if count == 0
      body.kind.expressions? && body.named_child_count == count + 1
    end

    # `|x, (a, b)|`: the text between the block's opening and the params'
    # closing pipe.
    private def self.param_text(text : String, blk : Syntax::Node, params : Syntax::Node) : String
      open = text.byte_index('|', blk.start_byte.to_i) || return ""
      close = text.byte_index('|', params.end_byte.to_i) || return ""
      text.byte_slice(open, close - open + 1)
    end

    # A call whose arguments (without parentheses) contain *call*.
    private def self.enclosing_unparenthesized_call(call : Syntax::Node) : Syntax::Node?
      node = call.parent
      while n = node
        # `x.try &.each { }`: the block belongs to the short-block call
        # whatever its form.
        return nil if n.kind.block? || n.kind.method_def? || n.kind.expressions? || n.kind.block_argument?
        if n.kind.argument_list? && (outer = n.parent) && outer.kind.call?
          # Operators (`xs << ys.map do ... end`) take one operand: no
          # precedence difference.
          return nil if outer.field(Syntax::Field::Method).try(&.kind.operator?)
          # `argument_list` starts at `(` when parenthesized.
          return outer.tree.text.byte_at(n.start_byte) == '('.ord ? nil : outer
        end
        node = n.parent
      end
      nil
    end

    # Would `{` bind to the last argument instead? Only when the call's
    # arguments are not parenthesized and the last one is a call that can
    # take a block (`foo bar`, `foo x.bar`), or a constant (`record Foo {`
    # is a `Foo{...}` literal); not `foo 1`, `foo x : T`.
    private def self.unparenthesized_args?(call : Syntax::Node, text : String) : Bool
      args = call.field(Syntax::Field::Arguments) || return false
      return false if args.named_child_count == 0
      return false if text.byte_at(args.start_byte) == '('.ord
      last = args.named_children.last
      # `c: x {` binds to `x` too: the named argument's value.
      if last.kind.named_expr?
        last = last.named_children.reject { |c| c == last.field(Syntax::Field::Name) }.last? || return false
      end
      # `record Foo {` reads as the literal `Foo { ... }`.
      last.kind.call? || last.kind.identifier? || last.kind.constant? || last.kind.generic_instance_type?
    end

    private def self.line_start(text : String, offset : UInt32) : UInt32
      i = offset
      while i > 0 && text.byte_at(i - 1) != '\n'.ord
        i -= 1
      end
      i
    end

    # Lines of *body* re-indented under *indent*, keeping their relative
    # indentation.
    private def self.reindent(body : String, indent : String) : String
      lines = body.lines
      # The first line has no leading indent (it starts at the body).
      rest = lines[1..].reject(&.strip.empty?)
      common = rest.map { |l| l[/\A[ \t]*/].size }.min? || 0
      result = [indent + lines[0].strip]
      lines[1..].each { |l| result << (l.strip.empty? ? "" : indent + l[common..].rstrip) }
      result.join('\n')
    end
  end
end
