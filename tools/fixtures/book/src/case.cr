require "./h"
var = cond ? 1 : (cond ? "s" : nil)
case var
when String
  __t(var)
when Int32
  __t(var)
else
  __t(var)
end
case var
when .nil?
  __t(var)
else
  __t(var)
end
k = case var
    when String then 1
    when Int32 then "s"
    end
__t(k)
case var
in String
  __t(var)
in Int32
  __t(var)
in nil
  __t(var)
end
enum Color
  Red
  Green
end
col = Color::Red
__t(col)
__t(Color::Red.value)
__t(Color.new(1))
case col
in .red?
  __t(col)
in .green?
  __t(col)
end
p1 = cond ? 1 : "s"
p2 = cond ? 'c' : nil
case {p1, p2}
when {String, Char}
  __t(p1)
  __t(p2)
end
case num = cond ? 1 : nil
when Int32
  __t(num)
end
m = case
    when cond then 1
    else 'c'
    end
__t(m)
