# CST dump including anonymous tokens and field names (`clear-ls dump-cst`
# hides anonymous nodes).
#
#   bin/probes/dump_cst_all FILE
require "../../src/clear_ls/syntax"
def d(n, f, depth)
  puts "#{"  " * depth}#{f.none? ? "" : "#{ClearLS::Syntax::FIELD_NAMES[f.value]}: "}#{n.missing? ? "MISSING " : ""}#{n.named? ? n.type : n.type.inspect}#{n.child_count == 0 ? " " + n.text.inspect : ""}"
  n.each_child_with_field { |c, ff| d(c, ff, depth + 1) }
end
t = ClearLS::Syntax::Parser.new.parse(File.read(ARGV[0]))
d(t.root, ClearLS::Syntax::Field::None, 0)
