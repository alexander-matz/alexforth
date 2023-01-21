--[[
    First attempt at building some kind of forth VM in lua, there are significant
    difference in the memory/dictionary layout and execution model. Especially the
    different memory layout limits how COLON and SEMICOLON can be implemented
    in forth itself.
    The execution model is different from standard forth implementations. Instead of
    running (directly or indirectly) threaded code, this VM implements worth as
    regular subroutines. As a consequence, the return stack is also implicit instead
    of explicit, which is likely to limit the degree of custimizability of the VM.
--]]

local STATE_COMPILE = 1
local STATE_IMMEDIATE = 0

local STATE = STATE_IMMEDIATE
local STDIN_BUFFER = nil
local MEMORY = {}
local DICTIONARY = {}
local D_STACK = {}

local function _push_ds(value)
    table.insert(D_STACK, value)
end

local function _peek_ds()
    if #D_STACK == 0 then
        error("Attemting to access empty stack")
    end
    local val = D_STACK[#D_STACK]
    return val
end

local function _pop_ds()
    local val = _peek_ds()
    table.remove(D_STACK)
    return val
end

local function _add_word(name, fn, immediate)
    assert(name:find("%s") == nil)
    assert(type(fn) == "function")
    table.insert(DICTIONARY, { name = string.upper(name), fn = fn, immediate = immediate or false })
end

local function _find(name)
    for idx=#DICTIONARY,1,-1 do
        if DICTIONARY[idx].name == string.upper(name) then
            return DICTIONARY[idx]
        end
    end
    return nil
end

local function _call(name)
    local entry = _find(name)
    if not entry then
        error(string.format("Did not a definition for word %s", name))
    end
    entry.fn()
end

local _exit = function() end

local function _make_word(start_idx)
    return function ()
        for idx = start_idx,#MEMORY,1 do
            local word = MEMORY[idx]
            if word == _exit then
                break
            end
            word()
        end
    end
end

_add_word("EXIT", _exit)

_add_word("MAKE_WORD", function ()
    local idx = _pop_ds()
    _push_ds(_make_word(idx))
end)

_add_word("MAKE_LIT", function ()
    local number = _pop_ds()
    _push_ds(function()
        _push_ds(number)
    end)
end)

_add_word("WORD", function ()
    if not STDIN_BUFFER then
        io.write(">>> ")
        io.flush()
        local err
        STDIN_BUFFER = io.read("*line")
        if not STDIN_BUFFER then
            os.exit(0)
        end
    end
    local first, last = STDIN_BUFFER:find("%S+")
    if not first then
        STDIN_BUFFER = nil
        return _call("WORD")
    end
    _push_ds(STDIN_BUFFER:sub(first, last))
    STDIN_BUFFER = STDIN_BUFFER:sub(last+1)
end)

_add_word("NUMBER", function ()
    local value = _pop_ds()
    local number = tonumber(value)
    if not number then
        error(string.format("Unable to parse '%s' as number", value))
    end
    _push_ds(number)
end)

_add_word("EMIT", function ()
    local ch = _pop_ds()
    io.write(string.format("%c", ch))
end)

_add_word("PRINT_STRING", function ()
    local text = _pop_ds()
    io.write(text)
end)

_add_word(",", function ()
    table.insert(MEMORY, _pop_ds())
end)

_add_word("MEM_HERE", function ()
    _push_ds(#MEMORY)
end)

_add_word("BIND", function ()
    local fn = _pop_ds()
    local name = _pop_ds()
    _add_word(name, fn)
end)

_add_word("FIND", function ()
    local name = _pop_ds()
    local entry = _find(name)
    if not entry then
        _push_ds(0)
    else
        _push_ds(entry)
    end
end)

_add_word(">CFA", function ()
    local entry = _pop_ds()
    _push_ds(entry.fn)
end)

_add_word("DUP", function ()
    local val = _pop_ds()
    _push_ds(val)
    _push_ds(val)
end)

_add_word("DROP", function ()
    _pop_ds()
end)

_add_word("SWAP", function ()
    local v1 = _pop_ds()
    local v2 = _pop_ds()
    _push_ds(v1)
    _push_ds(v2)
end)

_add_word("+", function ()
    local v1 = _pop_ds()
    local v2 = _pop_ds()
    _push_ds(v1 + v2)
end)

_add_word("-", function ()
    local v1 = _pop_ds()
    local v2 = _pop_ds()
    _push_ds(v2 - v1)
end)

_add_word(".", function ()
    local val = _pop_ds()
    assert(type(val) == "number")
    print(val)
end)

_add_word("INTERPRET", function ()
    _call("WORD")
    _call("DUP")
    _call("FIND")
    local result = _pop_ds()
    local number = false
    if result == 0 then
        _call("NUMBER")
        _call("MAKE_LIT")
        number = true
    else
        _call("DROP")
        _push_ds(result)
    end
    if STATE == STATE_IMMEDIATE then
        if not number then
            _call(">CFA")
        end
        local word_fn = _pop_ds()
        word_fn()
    else
        local entry = _peek_ds()
        if number then
            _call(",")
        elseif not entry.immediate then
            _call(">CFA")
            _call(",")
        else
            _pop_ds()
            entry.fn()
        end
    end
end)

_add_word("[", function ()
    print("STATE = compile")
    STATE = STATE_COMPILE
end)

_add_word("]", function ()
    print("STATE = immediate")
    STATE = STATE_IMMEDIATE
end)

_add_word(":", function ()
    _call("WORD")
    _call("MEM_HERE")
    _push_ds(1)
    _call("+")
    _call("[")
end)

_add_word(";", function ()
    _push_ds(_exit)
    _call(",")
    _call("MAKE_WORD")
    _call("BIND")
    _call("]")
end, true)

-------------------------------------------------------------------------------
-- EXPERIMENTS
-------------------------------------------------------------------------------


_add_word("DUMP", function()
    for idx = #D_STACK,1,-1 do
        print(string.format("%d: %s", idx, tostring(D_STACK[idx])))
    end
end)

;(function()
    _push_ds("MYDOT")

    _call("MEM_HERE")
    _push_ds(1)
    _call("+")

    _push_ds(".")
    _call("FIND")
    _call(">CFA")
    _call(",")

    _push_ds("EXIT")
    _call("FIND")
    _call(">CFA")
    _call(",")

    _call("MAKE_WORD")
    _call("BIND")
end)()

;(function()
    _push_ds("PRINT123")

    _call("MEM_HERE")
    _push_ds(1)
    _call("+")

    _push_ds(123)
    _call("MAKE_LIT")
    _call(",")

    _push_ds(".")
    _call("FIND")
    _call(">CFA")
    _call(",")

    _push_ds("EXIT")
    _call("FIND")
    _call(">CFA")
    _call(",")

    _call("MAKE_WORD")
    _call("BIND")
end)()

-------------------------------------------------------------------------------
-- MAIN LOOP
-------------------------------------------------------------------------------

_add_word("RUN_INTERACTIVE", function ()
    while true do
        _call("INTERPRET")
    end
end)

_call("RUN_INTERACTIVE")