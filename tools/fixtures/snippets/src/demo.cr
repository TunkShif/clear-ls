require "./models/user"

enum Color
  Red
  Green
end

def each_pair(&)
  yield "key", 1
end

def pick(c : Color, v : Int32 | String | Nil)
  case c
  in .red?
    1
  in .green?
    2
  end
end
# completion line below
x = 1
