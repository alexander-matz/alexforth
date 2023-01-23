--[[
    This is a high level implementation of the FORTH vm with identical
    semantics to the final VM, i.e. a FORTH program written for this
    vm should be valid and exhibit the same behavior on the final,
    assembly-based vm.

    The primary difference from jonesforth are:
    - Implemented in lua, not assembly
    - Support for arbitrary types on the DSTACK + MEM. This is currently
      used for strings, booleans, and function flags

    Lua supports proper tail calls by default. This is very convenient
    because it allows a straight forward implmenetation of the VM running
    indirect threaded code.
--]]

--------------------------------------
-- VM

MEM = {}

MEM[#MEM+1] = 0;
local _LATEST_ADDR = #MEM

MEM[#MEM+1] = 0; -- STATE = 0 -> immediate, STATE = 1 -> compile
local _STATE_ADDR = #MEM

DSTACK = {}
RSTACK = {}
NEXT_INST = nil
CODE_WORD = nil

--------------------------------------
-- INFRASTRUCTURE

-- These are normal helper functions and intended to be used
-- from lua code only, and not directly from forth

local function log(msg, ...)
    print(string.format(msg, ...))
end

local function _cfa(offset)
    return offset + 3
end

-- word header: link, name, flags, fn1, fn2, ...
local function _create(name, flags)
    local offset = #MEM+1
    table.insert(MEM, MEM[_LATEST_ADDR])
    table.insert(MEM, string.upper(name))
    table.insert(MEM, flags)
    MEM[_LATEST_ADDR] = offset
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

local function _popds()
    if #DSTACK == 0 then
        error("trying to access empty data stack")
    end
    return table.remove(DSTACK)
end

local function _pushds(value)
    table.insert(DSTACK, value)
end

local function _start_vm(code_word)
    NEXT_INST = nil
    CODE_WORD = code_word
    MEM[CODE_WORD]()
end

-- Interpreter for indirect threaded code
local function _next()
    -- Our return stack is still a mess at this point, so we need this
    if NEXT_INST == nil then
        return
    end
    CODE_WORD = MEM[NEXT_INST]
    NEXT_INST = NEXT_INST + 1
    return MEM[CODE_WORD]()
end

local function _wrap_next(fn)
    return function() fn() return _next() end
end

--------------------------------------
-- WORD DEFINITIONS

-- All of these operate on the data/return stack and can
-- be used from lua (via the _* functions) or from forth
-- via the REPL or the pointer to code worde returned by
-- _add_word

--------------------------------------

local function DOCOL()
    table.insert(RSTACK, NEXT_INST)
    NEXT_INST = CODE_WORD + 1
    return _next()
end

local function _EXIT()
    NEXT_INST = table.remove(RSTACK)
end
local EXIT = _add_word("EXIT", {}, _wrap_next(_EXIT))

local function VARADDR()
    _pushds(CODE_WORD + 1)
    return _next()
end

-- ( A -- A A )
local function _DUP()
    local val = _popds()
    _pushds(val)
    _pushds(val)
end
local DUP = _add_word("DUP", {}, _wrap_next(_DUP))

-- ( A -- )
local function _DROP()
    _popds()
end
local DROP = _add_word("DROP", {}, _wrap_next(_DROP))

-- ( A B -- B A )
local function _SWAP()
    local v1 = _popds()
    local v2 = _popds()
    _pushds(v1)
    _pushds(v2)
end
local SWAP = _add_word("SWAP", {}, _wrap_next(_SWAP))

-- ( A B -- A B A )
local function _OVER()
    local v1 = _popds()
    local v2 = _popds()
    _pushds(v2)
    _pushds(v1)
    _pushds(v2)
end
local OVER = _add_word("OVER", {}, _wrap_next(_OVER))

-- ( A B -- A B A B )
local function _TWODUP()
    local v1 = _popds()
    local v2 = _popds()
    _pushds(v2)
    _pushds(v1)
    _pushds(v2)
    _pushds(v1)
end
local TWODUP = _add_word("2DUP", {}, _wrap_next(_TWODUP))

-- ( A B -- )
local function _TWODROP()
    _popds()
    _popds()
end
local TWODROP = _add_word("2DROP", {}, _wrap_next(_TWODROP))

-- ( A B C D -- C D A B )
local function _TWOSWAP()
    local v1 = _popds()
    local v2 = _popds()
    local v3 = _popds()
    local v4 = _popds()
    _pushds(v2)
    _pushds(v1)
    _pushds(v4)
    _pushds(v3)
end
local TWOSWAP = _add_word("2SWAP", {}, _wrap_next(_TWOSWAP))

local function _LIT()
    local val = MEM[NEXT_INST]
    table.insert(DSTACK, val)
    NEXT_INST = NEXT_INST + 1
end
local LIT = _add_word("LIT", {}, _wrap_next(_LIT))

local LATEST = _add_word("LATEST", {}, DOCOL, {LIT, _LATEST_ADDR, EXIT})
local STATE = _add_word("STATE", {}, DOCOL, {LIT, _STATE_ADDR, EXIT})

local function _FETCH()
    local offset = _popds()
    _pushds(MEM[offset])
end
local FETCH = _add_word("@", {}, _wrap_next(_FETCH))

local function _STORE()
    local offset = _popds()
    local value = _popds()
    MEM[offset] = value
end
local STORE = _add_word("!", {}, _wrap_next(_STORE))

local function _HERE()
    _pushds(#MEM+1)
end
local HERE = _add_word("HERE", {}, _wrap_next(_HERE))

local function _FIND()
    local name = string.upper(_popds())
    local offset = MEM[_LATEST_ADDR]
    while offset ~= 0 do
        if MEM[offset + 1] == name then
            _pushds(offset)
            return
        end
        offset = MEM[offset]
    end
    _pushds(0)
end
local FIND = _add_word("FIND", {}, _wrap_next(_FIND))

local function _CFA()
    local offset = _popds()
    _pushds(_cfa(offset))
end
local CFA = _add_word(">CFA", {}, _wrap_next(_CFA))

local function _ISIMMEDIATE()
    local entry_offset = _popds()
    local flags = MEM[entry_offset + 2]
    _pushds(flags.immediate or false)
end
local ISIMMEDIATE = _add_word("ISIMMEDIATE", {}, _wrap_next(_ISIMMEDIATE))

local function _ADD()
    local v1 = _popds()
    local v2 = _popds()
    _pushds(v1 + v2)
end
local ADD = _add_word("+", {}, _wrap_next(_ADD))


local function _SUB()
    local v1 = _popds()
    local v2 = _popds()
    _pushds(v2 - v1)
end
local SUB = _add_word("-", {}, _wrap_next(_SUB))

-- ( n var - )
local ADDSTORE = _add_word("+!", {}, DOCOL, {
    SWAP, OVER, FETCH, ADD, SWAP, STORE, EXIT
})

-- ( n var - )
local SUBSTORE = _add_word("-!", {}, DOCOL, {
    SWAP, OVER, FETCH, SUB, SWAP, STORE, EXIT
})

-- Strings can be pushed directly onto the stack, hence _LIT
-- can be repurposed for strings as well
local LITSTRING = _add_word("LITSTRING", {}, _wrap_next(_LIT))

local function _TELL()
    print(_popds())
end
local TELL = _add_word("TELL", {}, _wrap_next(_TELL))

local _STDIN_BUFFER = nil
local _STDIN_POS = nil

local function _PROMPT()
    io.write(">>> ")
    io.flush()
    _STDIN_BUFFER = io.read("*line")
    if not _STDIN_BUFFER then
        os.exit(0)
    end
    _STDIN_BUFFER = _STDIN_BUFFER .. '\n'
    _STDIN_POS = 1
end

local function _KEY()
    if not _STDIN_BUFFER or _STDIN_POS > #_STDIN_BUFFER then
        _PROMPT()
    end
    _pushds(string.sub(_STDIN_BUFFER, _STDIN_POS, _STDIN_POS))
    _STDIN_POS = _STDIN_POS + 1
end
KEY = _add_word("KEY", {}, _wrap_next(_KEY))

local function _ISWS()
    local ch = _popds()
    _pushds(ch == ' ' or ch == '\n' or ch == '\t')
end
ISWS = _add_word("ISWS", {}, _wrap_next(_ISWS))

local function _WORD()
    local function _KEY_CHECK()
        _KEY()
        _DUP()
        _ISWS()
    end
    _KEY_CHECK()
    while _popds() do
        _popds()
        _KEY_CHECK()
    end
    local buf = { _popds() }
    _KEY_CHECK()
    while not _popds() do
        table.insert(buf, _popds())
        _KEY_CHECK()
    end
    _popds()
    local word = table.concat(buf)
    _pushds(word)
end
local WORD = _add_word("WORD", {}, _wrap_next(_WORD))

local function _NUMBER()
    local value = _popds()
    local number = tonumber(value)
    if not number then
        error(string.format("Unable to parse '%s' as number", value))
    end
    _pushds(number)
end
local NUMBER = _add_word("NUMBER", {}, _wrap_next(_NUMBER))

local function _DUMP()
    for idx = #DSTACK,1,-1 do
        print(string.format("%d: %s", idx, tostring(DSTACK[idx])))
    end
end
local DUMP = _add_word("DUMP", {}, _wrap_next(_DUMP))

local function _DOT()
    print(string.format("%d", _popds()))
end
local DOT = _add_word(".", {}, _wrap_next(_DOT))

local function _COMMA()
    MEM[#MEM+1] = _popds()
end
local COMMA = _add_word(",", {}, _wrap_next(_COMMA))

local LBRAC = _add_word("[", {}, DOCOL, { LIT, 0, STATE, STORE, EXIT })
local RBRAC = _add_word("]", {}, DOCOL, { LIT, 1, STATE, STORE, EXIT })

local function _BRANCH()
    NEXT_INST = NEXT_INST + MEM[NEXT_INST]
end
local BRANCH = _add_word("BRANCH", {}, _wrap_next(_BRANCH))

local function _ZBRANCH()
    local test = _popds()
    if test == 0 or test == false then
        NEXT_INST = NEXT_INST + MEM[NEXT_INST]
    else
        NEXT_INST = NEXT_INST + 1
    end
end
local ZBRANCH = _add_word("0BRANCH", {}, _wrap_next(_ZBRANCH))

local function _CREATE()
    local name = _popds()
    local flags = {}
    _create(name, flags)
end
local CREATE = _add_word("CREATE", {}, _wrap_next(_CREATE))

local VARIABLE = _add_word("VARIABLE", {}, DOCOL, {
    WORD, CREATE,
    LIT, VARADDR, COMMA,
    LIT, 0, COMMA,
    EXIT
})

local COLON = _add_word(":", {}, DOCOL, {
    WORD, CREATE,
    LIT, DOCOL, COMMA,
    RBRAC,
    EXIT
})

local SEMICOLON = _add_word(";", { immediate = true }, DOCOL, {
    LIT, EXIT, COMMA,
    LBRAC,
    EXIT
})

local function _PEEKMEM()
    local length = _popds()
    local copy = {}
    for i = #MEM-length,#MEM,1 do
        table.insert(copy, MEM[i])
    end
    print(_format_data(copy))
end
local PEEKMEM = _add_word("PEEKMEM", {}, _wrap_next(_PEEKMEM))

local function _INTERPRET()
    _WORD()
    _DUP()
    _FIND()
    local entry = _popds()
    if entry == 0 then
        _NUMBER()
        if MEM[_STATE_ADDR] == 1 then -- compile
            _pushds(LIT)
            _COMMA()
            _COMMA()
        end
    else
        _DROP()
        _pushds(entry)
        if MEM[_STATE_ADDR] == 0 then -- immediate
            _CFA()
            CODE_WORD = _popds()
            return MEM[CODE_WORD]()
        else
            _DUP()
            _ISIMMEDIATE()
            local is_immediate = _popds()
            _CFA()
            if is_immediate then
                CODE_WORD = _popds()
                return MEM[CODE_WORD]()
            else
                _COMMA()
            end
        end
    end
end
local INTERPRET = _add_word("INTERPRET", {}, _wrap_next(_INTERPRET))

QUIT = _add_word("QUIT", {}, DOCOL, {INTERPRET, BRANCH, -2, EXIT})

MYSUB = _add_word("MYSUB", {}, DOCOL, {LIT, 1337, DOT, EXIT})
MYPROGRAM = _add_word("MYPROGRAM", {}, DOCOL, {LITSTRING, "Some String", TELL, LIT, 2, LIT, 3, MYSUB, LIT, 4, DUMP, EXIT})
TESTVAR = _add_word("TESTVAR", {}, VARADDR, {0})
BRANCHTEST = _add_word("BRANCHTEST", {}, DOCOL, {LIT, 1, BRANCH, 3, LIT, 2, LIT, 3, DUMP, EXIT})

_start_vm(QUIT)