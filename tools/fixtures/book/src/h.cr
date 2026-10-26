macro __t(x)
  __probe(({{x}}), StaticArray(UInt8, {{@caller.first.line_number}}))
end
def __probe(x : T, l : StaticArray(UInt8, L).class) forall T, L
  {% puts "@#{L} #{T}" %}
end
def cond : Bool
  rand < 0.5
end
