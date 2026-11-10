require "./annotations"

module ClearLS::IDE
  # Arguments of an annotation type, from tables only: the compiler's
  # built-ins (`Annotations::BUILTINS`) and the stdlib's own annotations
  # (`Annotations::STDLIB_ARGS`). Other annotations (shards, user code)
  # have none: their docs follow no fixed format, and the macros that
  # read them are linked to the use site only by name at expansion time.
  module AnnotationArgs
    # Arguments of the annotation written as *path* at namespace *ns*,
    # with its full name; nil when *path* is no annotation or its
    # arguments are unknown. *library_file*: whether a file is in the
    # stdlib (a stdlib table entry applies only to the stdlib's
    # declaration, not to a user's `module JSON; annotation Field`).
    def self.for_path(map : Semantics::DefMap, ns : Semantics::TypeId, path : String, stdlib_file : FileId -> Bool) : {String, Array(Annotations::Arg)}?
      from = Annotations::TOP_LEVEL.includes?(path) ? Semantics::DefMap::PROGRAM : ns
      if id = map.lookup_path(path, from)
        info = map[id]
        return nil unless info.kind.annotation?
        full = info.full_name
        top = info.namespace.nil? || info.namespace == Semantics::DefMap::PROGRAM
        if top && (b = Annotations.builtin?(full))
          return {full, b.args}
        end
        args = Annotations::STDLIB_ARGS[full]? || return nil
        return nil unless info.sites.all? { |s| stdlib_file.call(s.file) }
        return {full, args}
      end
      b = Annotations.builtin?(path) || return nil
      {b.name, b.args}
    end
  end
end
