require "../items"
require "../syntax"

module ClearLS::IDE
  # Docs of what the compiler implements without a source declaration:
  # pseudo-methods (`sizeof`, `pointerof`, `typeof`, `x.is_a?`, ...) and
  # the types `Void` and `NoReturn`. Read from the stdlib's
  # `docs_pseudo_methods.cr`, where the docs generator finds them (as
  # `__crystal_pseudo_<name>` defs and `CRYSTAL_PSEUDO__<Name>` structs);
  # nothing is copied, so they follow the installed Crystal.
  module PseudoDocs
    record Entry, name : String, signature : String, doc : String?,
      # Object method (`x.is_a?`) rather than top-level (`sizeof(T)`).
      method : Bool = false,
      type : Bool = false

    @@cache = {} of String => Hash(String, Entry)
    @@lock = Mutex.new

    FILE = "docs_pseudo_methods.cr"

    # Entries of the stdlib at *stdlib_dir* by name (`sizeof`,
    # `Object#is_a?`, `Void`); empty when the file is missing.
    def self.entries(stdlib_dir : String?) : Hash(String, Entry)
      dir = stdlib_dir || return {} of String => Entry
      @@lock.synchronize do
        @@cache[dir] ||= load(File.join(dir, FILE))
      end
    end

    def self.lookup(stdlib_dir : String?, key : String) : Entry?
      entries(stdlib_dir)[key]?
    end

    private def self.load(path : String) : Hash(String, Entry)
      result = {} of String => Entry
      return result unless File.file?(path)
      tree = Items::Lower.lower(Syntax::Parser.new.parse(File.read(path)))
      tree.items.each do |item|
        if item.kind.def? && (name = item.name.lchop?("__crystal_pseudo_"))
          result[name] = Entry.new(name, "#{name}#{item.signature}", item.doc)
        elsif item.kind.struct? && (name = item.name.lchop?("CRYSTAL_PSEUDO__"))
          result[name] = Entry.new(name, name, item.doc, type: true)
        elsif item.kind.class? && item.name == "Object"
          item.children.each do |m|
            next unless m.kind.def? && (name = m.name.lchop?("__crystal_pseudo_"))
            result["Object##{name}"] = Entry.new(name, "#{name}#{m.signature}", m.doc, method: true)
          end
        end
      end
      result
    rescue File::Error
      {} of String => Entry
    end

    def self.markdown(e : Entry) : String
      String.build do |io|
        io << "```crystal\n"
        if e.type
          io << "struct " << e.name
        elsif e.method
          io << "def Object#" << e.signature
        else
          io << e.signature
        end
        io << "\n```\n\nbuilt into the compiler"
        if doc = e.doc
          io << "\n\n" << doc
        end
      end
    end
  end
end
