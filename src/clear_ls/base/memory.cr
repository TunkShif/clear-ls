module ClearLS
  # Returns free libc heap memory to the OS.
  #
  # Tree-sitter allocates with libc malloc (`-Dcrystal_tree_sitter_no_init`).
  # Parsing on parallel workers leaves each thread's malloc arena full of
  # freed blocks after the trees are dropped: on Marten 130 of 234 MB RSS
  # right after indexing; `malloc_trim` gives it back in ~20 ms. Call it
  # after a batch of native allocations is released (indexing, a large
  # search). No-op where glibc's `malloc_trim` doesn't exist.
  module Memory
    {% if flag?(:linux) && flag?(:gnu) %}
      lib LibMalloc
        fun malloc_trim(pad : LibC::SizeT) : LibC::Int
      end

      def self.trim : Nil
        LibMalloc.malloc_trim(0)
      end
    {% else %}
      def self.trim : Nil
      end
    {% end %}
  end
end
