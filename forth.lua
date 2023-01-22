--[[
    This is a high level implementation of the FORTH vm with identical
    semantics to the final VM, i.e. a FORTH program written for this
    vm should be valid and exhibit the same behavior on the final,
    assembly-based vm.

    The primary difference from jonesforth are:
    - Implemented in lua, not assembly
    - Support for arbitrary types on the DSTACK + MEM. This is currently
      used for strings and function flags

    Lua supports proper tail calls by default. This is very convenient
    because it allows a straight forward implmenetation of the VM running
    indirect threaded code.
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
CODE_WORD = nil
STATE = STATE_IMMEDIATE

--------------------------------------

local function log(msg, ...)
    print(string.format(msg, ...))
end

local _cfa

-- word header: link, name, flags, fn1, fn2, ...
local function _create(name, flags)
    local offset = #MEM+1
    if LATEST ~= nil then
        MEM[LATEST] = offset
    end
    table.insert(MEM, false) -- false instead of nil for link field to avoid sparse arrays
    table.insert(MEM, name)
    table.insert(MEM, flags)
    return offset
end

local function _format_data(data)
    if data == nil then
        return "nil"
    end
    local parts = {}
    for idx, val in ipairs(data) do
        if type(val) == "function" then
            table.insert(parts, "{fn}")
        else
            table.insert(parts, tostring(val))
        end
    end
    return "[" .. table.concat(parts, ", ") .. "]"
end

local function _add_word(name, flags, code, data)
    assert(type(code) == "function")
    assert(data == nil or type(data) == "table")
    local offset = _create(name, flags)
    local cfa = _cfa(offset)
    table.insert(MEM, code)
    if data then
        for _, value in ipairs(data) do
            table.insert(MEM, value)
        end
    end
    -- log("adding word %s at %d, #data: %d", name, cfa, #(data or {}))
    return cfa
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

_cfa = function (offset)
    return offset + 3
end

local function _start_vm(code_word)
    NEXT_INST = nil
    CODE_WORD = code_word
    MEM[CODE_WORD]()
end

-- Interpreter for indirect threaded code
local function _next()
    CODE_WORD = MEM[NEXT_INST]
    NEXT_INST = NEXT_INST + 1
    return MEM[CODE_WORD]()
end

function _DOCOL()
    table.insert(RSTACK, NEXT_INST)
    NEXT_INST = CODE_WORD + 1
    return _next()
end
DOCOL = _DOCOL

function _EXIT()
    NEXT_INST = table.remove(RSTACK)
    if NEXT_INST ~= nil then
        return _next()
    end
end
EXIT = _add_word("EXIT", {}, _EXIT)

function _LIT()
    local val = MEM[NEXT_INST]
    table.insert(DSTACK, val)
    NEXT_INST = NEXT_INST + 1
    return _next()
end
LIT = _add_word("LIT", {}, _LIT)

function _WORD()
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
WORD = _add_word("WORD", {}, _WORD)

function _DUMP()
    for idx = #DSTACK,1,-1 do
        print(string.format("%d: %s", idx, tostring(DSTACK[idx])))
    end
    return _next()
end
DUMP = _add_word("DUMP", {}, _DUMP)

function _DOT()
    print(string.format("%d", _popds()))
    return _next()
end
DOT = _add_word(".", {}, _DOT)

MYSUB = _add_word("MYSUB", {}, DOCOL, {LIT, 1337, DOT, EXIT})
MYPROGRAM = _add_word("MYPROGRAM", {}, DOCOL, {WORD, LIT, 2, LIT, 3, MYSUB, LIT, 4, DUMP, EXIT})

_start_vm(MYPROGRAM)