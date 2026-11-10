require "./annotations"

module ClearLS::IDE
  # Arguments of an annotation type: the compiler's for built-ins
  # (`Annotations::BUILTINS`), else the stdlib's doc convention: a line
  # naming the annotation (`` `JSON::Field` properties: ``, ``### Class
  # annotation `JSON::Serializable::Options` ``) followed by
  # `* **name**: text` bullets, in the doc of any declaration of a file
  # that declares the annotation (`JSON::Field`'s are on
  # `JSON::Serializable`), or the annotation's own doc.
  module AnnotationArgs
    BULLET = /\A\s*\*\s+\*\*([a-z_]\w*)\*\*:\s*(.*)\z/

    # In an annotation's own doc only (other docs list methods the same
    # way): `` * `name : Type` - text `` / `` - `name` — text ``
    # (Athena's `ADI::Register`, `ASRA::Name`).
    CODE_BULLET = /\A\s*[*-]\s+`([a-z_]\w*)(?:\s*:\s*([^`]+))?`\s*[-—:]\s*(.*)\z/

    # In an annotation's own doc only: a heading naming the argument,
    # then `**Type:** `T`` within a few lines, then its text (Athena's
    # `ACONA::AsCommand`, `ARTA::Route`, ORM annotations).
    HEADING = /\A\s*\#{2,4}\s+([a-z_]\w*)\s*\z/
    TYPE_LINE = /\A\s*\*\*Type:\*\*\s*`([^`]+)`/

    # How many lines may separate the line naming the annotation from
    # its first bullet (`supported properties:`, a blank line).
    MAX_GAP = 3

    # *full_name*: the annotation's full name (`JSON::Field`); *docs*:
    # candidate doc texts (the annotation's own first).
    def self.from_docs(full_name : String, docs : Enumerable(String)) : Array(Annotations::Arg)
      mention = "`#{full_name}`"
      global = "`::#{full_name}`"
      docs.each_with_index do |doc, i|
        lines = doc.lines
        if i == 0
          own = bullets(lines, 0) || [] of Annotations::Arg
          own = code_bullets(lines) if own.empty?
          own = headings(lines) if own.empty?
          return own unless own.empty?
        end
        lines.each_with_index do |line, k|
          next unless line.includes?(mention) || line.includes?(global)
          found = bullets(lines, k + 1)
          return found if found && !found.empty?
        end
      end
      [] of Annotations::Arg
    end

    # The bullets starting within `MAX_GAP` lines of *from*.
    private def self.bullets(lines : Array(String), from : Int32) : Array(Annotations::Arg)?
      start = (from...Math.min(from + MAX_GAP + 1, lines.size)).find { |k| lines[k].matches?(BULLET) } || return nil
      args = [] of Annotations::Arg
      k = start
      while k < lines.size && (m = lines[k].match(BULLET))
        args << Annotations::Arg.new(m[1], "", m[2].strip)
        k += 1
      end
      args
    end

    # The first run of `CODE_BULLET` lines (one list).
    private def self.code_bullets(lines : Array(String)) : Array(Annotations::Arg)
      args = [] of Annotations::Arg
      start = lines.index { |l| l.matches?(CODE_BULLET) } || return args
      k = start
      while k < lines.size && (m = lines[k].match(CODE_BULLET))
        args << Annotations::Arg.new(m[1], m[2]?.try(&.strip) || "", m[3].strip)
        k += 1
      end
      args
    end

    # `HEADING` followed by `TYPE_LINE`; the text is the paragraph after
    # the type line, up to a blank line, rule or heading.
    private def self.headings(lines : Array(String)) : Array(Annotations::Arg)
      args = [] of Annotations::Arg
      lines.each_with_index do |line, k|
        m = line.match(HEADING) || next
        t = (k + 1..Math.min(k + MAX_GAP, lines.size - 1)).find { |j| lines[j].matches?(TYPE_LINE) } || next
        type = lines[t].match(TYPE_LINE).not_nil![1]
        j = t + 1
        while j < lines.size && lines[j].strip.empty?
          j += 1
        end
        text = [] of String
        while j < lines.size && !(s = lines[j].strip).empty? && !s.starts_with?('#') && !s.starts_with?("---") && !s.starts_with?("```")
          text << s
          j += 1
        end
        args << Annotations::Arg.new(m[1], type, text.join(' '))
      end
      args
    end

    # Arguments of the annotation type *id* in *map*; *docs_of* gives
    # every declaration doc of a file.
    def self.of(map : Semantics::DefMap, id : Semantics::TypeId, docs_of : FileId -> Array(String)) : Array(Annotations::Arg)
      info = map[id]
      if b = Annotations.builtin?(info.full_name)
        return b.args if info.namespace.nil? || info.namespace == Semantics::DefMap::PROGRAM
      end
      docs = [] of String
      info.sites.each { |s| s.item.doc.try { |d| docs << d } }
      docs << "" if docs.empty? # keeps index 0 as "own doc"
      info.sites.map(&.file).uniq.each { |f| docs.concat(docs_of.call(f)) }
      from_docs(info.full_name, docs)
    end

    # Arguments of the annotation written as *path* at namespace *ns*,
    # with its full name; nil when *path* is no annotation.
    def self.for_path(map : Semantics::DefMap, ns : Semantics::TypeId, path : String, docs_of : FileId -> Array(String)) : {String, Array(Annotations::Arg)}?
      from = Annotations::TOP_LEVEL.includes?(path) ? Semantics::DefMap::PROGRAM : ns
      if id = map.lookup_path(path, from)
        return nil unless map[id].kind.annotation?
        return {map[id].full_name, of(map, id, docs_of)}
      end
      b = Annotations.builtin?(path) || return nil
      {b.name, b.args}
    end

    # Declaration docs of an indexed file, in source order.
    def self.file_docs(index : Workspace::Index, file : FileId) : Array(String)
      entry = index.entry?(file) || return [] of String
      docs = [] of String
      entry.items.each_item { |it| it.doc.try { |d| docs << d } }
      docs
    end
  end
end
