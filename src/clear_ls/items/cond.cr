module ClearLS::Items
  # Macro condition guarding declarations or requires, e.g. the
  # `flag?(:linux) && !flag?(:musl)` in `{% if ... %}`.
  #
  # Evaluation is three-valued: `nil` means "unknown" (anything other than
  # `flag?` and boolean operators, e.g. `compare_versions(...)`).
  abstract class Cond
    abstract def eval(flags : Set(String)) : Bool?
    abstract def to_s(io : IO) : Nil

    class Flag < Cond
      getter name : String

      def initialize(@name)
      end

      def eval(flags : Set(String)) : Bool?
        flags.includes?(@name)
      end

      def to_s(io : IO) : Nil
        io << "flag?(:" << @name << ')'
      end
    end

    class Not < Cond
      getter inner : Cond

      def initialize(@inner)
      end

      def eval(flags : Set(String)) : Bool?
        v = @inner.eval(flags)
        v.nil? ? nil : !v
      end

      def to_s(io : IO) : Nil
        io << '!' << @inner
      end
    end

    class And < Cond
      def initialize(@left : Cond, @right : Cond)
      end

      def eval(flags : Set(String)) : Bool?
        l, r = @left.eval(flags), @right.eval(flags)
        return false if l == false || r == false
        return nil if l.nil? || r.nil?
        true
      end

      def to_s(io : IO) : Nil
        io << '(' << @left << " && " << @right << ')'
      end
    end

    class Or < Cond
      def initialize(@left : Cond, @right : Cond)
      end

      def eval(flags : Set(String)) : Bool?
        l, r = @left.eval(flags), @right.eval(flags)
        return true if l == true || r == true
        return nil if l.nil? || r.nil?
        false
      end

      def to_s(io : IO) : Nil
        io << '(' << @left << " || " << @right << ')'
      end
    end

    class Unknown < Cond
      getter text : String

      def initialize(@text)
      end

      def eval(flags : Set(String)) : Bool?
        nil
      end

      def to_s(io : IO) : Nil
        io << '{' << @text << '}'
      end
    end

    # Conjunction of a condition list: false if any is false, nil if any
    # unknown, else true.
    def self.all(conds : Enumerable(Cond), flags : Set(String)) : Bool?
      result = true
      conds.each do |c|
        case c.eval(flags)
        when false then return false
        when nil   then result = nil
        end
      end
      result
    end
  end

  # Target flags as the compiler computes them (semantic/flags.cr), derived
  # from a target triple such as `x86_64-unknown-linux-gnu`.
  def self.flags_for_triple(triple : String) : Set(String)
    arch, vendor, rest = triple.split('-', 3) + [""] * 2
    flags = Set{arch, vendor}
    rest.split('-').each { |part| flags << part unless part.empty? }
    flags << (arch.in?("x86_64", "aarch64") ? "bits64" : "bits32")
    os = rest
    flags << "unix" unless os.includes?("windows") || os.includes?("wasi")
    flags << "win32" if os.includes?("windows")
    flags << "darwin" if os.includes?("darwin") || os.includes?("macos")
    flags << "linux" if os.includes?("linux")
    bsd = %w(freebsd netbsd openbsd dragonfly).find { |b| os.includes?(b) }
    if bsd
      flags << bsd << "bsd"
    end
    flags << "android" if os.includes?("android")
    flags.delete("")
    flags
  end
end
