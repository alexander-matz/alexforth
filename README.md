# ALEXFORTH

alexforth is a forth implementation purely intended for educational purposes.
It is currently implemented in lua, but might slowly transition to an assembly
based implementation.

The project is closely inspired, or loosely based, on the jonesforth tutorial:
https://rwmj.wordpress.com/2010/08/07/jonesforth-git-repository/

Lua as the implementation was chosen for two reasons:
- Tail calls are directly supported, making it easy to implement threaded code. In
  C, functions that don't return are a bit iffy.
- The existence of DynASM might allow for a gradual transition to assembly.

# PUBLIC DOMAIN

I, the copyright holder of this work, hereby release it into the public domain.
This applies worldwide. In case this is not legally possible, I grant any entity
the right to use this work for any purpose, without any conditions, unless such
conditions are required by law.