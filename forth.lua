--[[
    This is a high level implementation of the FORTH vm with identical
    semantics to the final VM, i.e. a FORTH program written for this
    vm should be valid and exhibit the same behavior on the final,
    assembly-based vm.

    The main exception here is that
    Exceptions are:
    - Handling of strings. Strings are pushed to the data stack directly
        instead of as start + end addresses
    - Data

    Lua supports proper tail calls by default. This is very convenient
    because it allows to implement the vm with indirect thread code
    right away.
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
LAST_JMPED_INST = nil
STATE = STATE_IMMEDIATE

--------------------------------------

local function log(msg, ...)
    print(string.format(msg, ...))
end

-- word header: link, name, flags, fn1, fn2, ...
local function _add_word(name, flags, code)
    assert(type(code) == "table")
    local OFFSET = #MEM+1
    log("Word %s code starting at %d", name, OFFSET+3)
    if LATEST ~= nil then
        MEM[LATEST] = OFFSET
    end
    MEM[OFFSET+0] = nil
    MEM[OFFSET+1] = name
    MEM[OFFSET+2] = flags
    for idx, fn in ipairs(code) do
        MEM[OFFSET+2 + idx] = fn
    end
    return OFFSET
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

local function _popds()
    if #DSTACK == 0 then
        error("trying to access empty data stack")
    end
    return table.remove(DSTACK)
end

local function _cfa(offset)
    return offset + 3
end

local function _next()
    LAST_JMPED_INST = NEXT_INST
    NEXT_INST = NEXT_INST + 1
    return MEM[LAST_JMPED_INST]()
end

function EXIT()
    NEXT_INST = table.remove(RSTACK)
    log("EXIT popped address %s", NEXT_INST)
    if NEXT_INST ~= nil then
        return _next()
    end
end
_add_word("EXIT", {}, {EXIT})

function DOCOL()
    table.insert(RSTACK, NEXT_INST)
    NEXT_INST = LAST_JMPED_INST + 1
    return _next()
end
_add_word("DOCOL", {}, {DOCOL})

function LIT()
    local val = MEM[NEXT_INST]
    table.insert(DSTACK, val)
    NEXT_INST = NEXT_INST + 1
    return _next()
end
_add_word("LIT", {}, {LIT})

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
_add_word("WORD", {}, {WORD})

function DUMP()
    for idx = #DSTACK,1,-1 do
        print(string.format("%d: %s", idx, tostring(DSTACK[idx])))
    end
    return _next()
end
_add_word("DUMP", {}, {DUMP})

function DOT()
    print(string.format("%d", _popds()))
    return _next()
end
_add_word(".", {}, {DOT})

MYSUB = _cfa(_add_word("MYSUB", {}, {DOCOL, LIT, 1337, DOT, EXIT}))
MYPROGRAM = _cfa(_add_word("MYPROGRAM", {}, {DOCOL, WORD, LIT, 2, LIT, 3, MEM[MYSUB], LIT, 4, DUMP, EXIT}))

LAST_JMPED_INST = MYPROGRAM
NEXT_INST = nil
MEM[MYPROGRAM]()