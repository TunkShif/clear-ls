class Item
  getter name : String
  getter price : Int32
  def initialize(@name, @price)
  end
  def label
    "#{name}: #{price}"
  end
  def discounted(pct)
    price * pct // 100
  end
end

def chains(items : Array(Item), h : Hash(String, Int32), t : {Int32, String})
  names = items.map(&.name)
  maybe = items.map { |i| i.name if i.price > 0 }
  compact = maybe.compact
  cm = items.compact_map { |i| i.name if i.price > 0 }
  found = items.find { |i| i.price > 1 }
  total = items.reduce(0) { |acc, i| acc + i.price }
  sum = items.sum(&.price)
  sorted = items.sort_by(&.price)
  grouped = items.group_by(&.name)
  first = items.first
  label = first.label
  disc = first.discounted(10)
  hv = h["x"]
  hq = h["x"]?
  hk = h.keys
  hm = h.map { |k, v| v }
  hs = h.select { |k, v| v > 1 }
  tf = t[0]
  ts = t[1]
  sel = items.select { |i| i.price > 1 }
  idx = items.index { |i| i.price > 1 }
  zipped = names.zip(items)
  each_s = items.each_slice(2).to_a
  minb = items.min_by(&.price)
  tally = names.tally
  joined = names.join(", ")
  uniq = names.uniq
  flat = [[1], [2]].flatten
  hash2 = items.to_h { |i| {i.name, i} }
  cnt = items.count { |i| i.price > 1 }
  any = items.any? { |i| i.price > 1 }
  parts = "a,b".split(',').map(&.strip)
  ints = "1 2".split.map(&.to_i)
end
