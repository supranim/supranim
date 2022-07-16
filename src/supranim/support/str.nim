# Supranim is a simple MVC-style web framework for building
# fast web applications, REST API microservices and other cool things.
#
# (c) 2022 Supranim is released under MIT License
#          Made by Humans from OpenPeep
#          https://supranim.com | https://github.com/supranim

proc unquote*(s: string): string =
    if s.len == 0: return
    if s[0] == '"' and s[^1] == '"':
        return s[1 .. ^2]
    result = s