require "json"

class Item
  getter title : String
  getter tags = [] of String

  def initialize(@title : String)
  end
end

def report(items : Array(Item), io : IO)
  titles = items.map { |i| i.title }
  longest = titles.max_by? { |t| t.size }
  counts = Hash(String, Int32).new(0)
  items.each do |item|
    item.tags.each { |tag| counts[tag] += 1 }
  end
  line = io.gets
  if line
    stripped = line.strip
  end
  
end
