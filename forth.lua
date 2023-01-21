--[[
    This is a high level implementation of the FORTH vm with identical
    semantics to the final VM, i.e. a FORTH program written for this
    vm should be valid and exhibit the same behavior on the final,
    assembly-based vm.

    The primary difference from jonesforth are:
    - Support for arbitrary types on the DSTACK + MEM. This is currently
      used for strings and function flags
    - Direct threaded code instead of indirect threaded code

    Lua supports proper tail calls by default. This is very convenient
    because it allows to implement the vm running (direct/indirect)
    threaded code right away. The current implementation uses
    direct threaded code, as MEM[NEXT_INST] is expected to contain
--]]

--------------------------------------
-- CONSTANTS

STATE_IMMEDIATE = 0
STATE_COMPILE = 1

--------------------------------------
-- VM

MEM = {}
LATEST = nil

DSTACK = {}
RSTACK = {}
NEXT_INST = nil
STATE = STATE_IMMEDIATE

--------------------------------------

local function log(msg, ...)
    print(string.format(msg, ...))
end

local _cfa
local _docol

-- word header: link, name, flags, fn1, fn2, ...
local function _create(name, flags)
    local OFFSET = #MEM+1
    if LATEST ~= nil then
        MEM[LATEST] = OFFSET
    end
    table.insert(MEM, false) -- false instead of nil for link to avoid sparse arrays
    table.insert(MEM, name)
    table.insert(MEM, flags)
    return OFFSET
end

local function _add_word(name, flags, code)
    assert(type(code) == "table")
    local OFFSET = _create(name, flags)
    table.insert(MEM, _docol(#MEM+1))
    for _, fn in ipairs(code) do
        table.insert(MEM, fn)
    end
    table.insert(MEM, EXIT)
    return _cfa(OFFSET)
end

local function _add_native(name, flags, code)
    assert(type(code) == "table")
    local OFFSET = _create(name, flags)
    for _, fn in ipairs(code) do
        table.insert(MEM, fn)
    end
    return _cfa(OFFSET)
end

local function _find(name)
    local offset = LATEST
    while offset ~= nil do
        if MEM[offset + 1] == name then
            return offset
        end
        offset = MEM[offset]
    end
end

local function _popds ()
    if #DSTACK == 0 then
        error("trying to access empty data stack")
    end
    return table.remove(DSTACK)
end

_cfa = function (offset)
    return offset + 3
end

local function _next()
    local target = NEXT_INST
    NEXT_INST = NEXT_INST + 1
    return MEM[target]()
end

-- Embedding the next location here is required
-- because this VM currently runs direct threaded
-- code and a function is not aware
-- "where it was called from".
_docol = function (location)
    local function DOCOL()
        table.insert(RSTACK, NEXT_INST)
        NEXT_INST = location + 1
        return _next()
    end
    return DOCOL
end

function EXIT()
    NEXT_INST = table.remove(RSTACK)
    if NEXT_INST ~= nil then
        return _next()
    end
end
_add_native("EXIT", {}, {EXIT})

function LIT()
    local val = MEM[NEXT_INST]
    table.insert(DSTACK, val)
    NEXT_INST = NEXT_INST + 1
    return _next()
end
_add_native("LIT", {}, {LIT})

function WORD()
    while true do
        if not STDIN_BUFFER then
            io.write(">>> ")
            io.flush()
            STDIN_BUFFER = io.read("*line")
            if not STDIN_BUFFER then
                os.exit(0)
            end
        end
        local first, last = STDIN_BUFFER:find("%S+")
        if first then
            table.insert(DSTACK, STDIN_BUFFER:sub(first, last))
            STDIN_BUFFER = STDIN_BUFFER:sub(last+1)
            return _next()
        end
    end
end
_add_native("WORD", {}, {WORD})

function DUMP()
    for idx = #DSTACK,1,-1 do
        print(string.format("%d: %s", idx, tostring(DSTACK[idx])))
    end
    return _next()
end
_add_native("DUMP", {}, {DUMP})

function DOT()
    print(string.format("%d", _popds()))
    return _next()
end
_add_native(".", {}, {DOT})

MYSUB = _add_word("MYSUB", {}, {LIT, 1337, DOT})
MYPROGRAM = _add_word("MYPROGRAM", {}, {WORD, LIT, 2, LIT, 3, MEM[MYSUB], LIT, 4, DUMP})

NEXT_INST = nil
MEM[MYPROGRAM]()