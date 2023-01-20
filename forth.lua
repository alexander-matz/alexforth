local MODE_COMPILE = 1
local MODE_IMMEDIATE = 0

local MODE = MODE_IMMEDIATE
local STDIN_BUFFER = nil
local MEMORY = {}
local DICTIONARY = {}
local D_STACK = {}

local function _push_ds(value)
    table.insert(D_STACK, value)
end

local function _pop_ds()
    if #D_STACK == 0 then
        error("Attemting to pop from empty stack")
    end
    local val = D_STACK[#D_STACK]
    table.remove(D_STACK)
    return val
end

local function _add_word(name, fn)
    assert(name:find("%s") == nil)
    assert(type(fn) == "function")
    table.insert(DICTIONARY, { name = string.upper(name), fn = fn })
end

local function _find(name)
    for idx=#DICTIONARY,1,-1 do
        if DICTIONARY[idx].name == string.upper(name) then
            return DICTIONARY[idx].fn
        end
    end
    return nil
end

local function _call(name)
    local fn = _find(name)
    if not fn then
        error(string.format("Did not a definition for word %s", name))
    end
    fn()
end

local _exit = function() end

local function _make_word(start_idx)
    return function()
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

_add_word("FIND", function ()
    local name = _pop_ds()
    local fn = _find(name)
    if not fn then
        _push_ds(0)
    else
        _push_ds(fn)
    end
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

_add_word(".", function ()
    local val = _pop_ds()
    assert(type(val) == "number")
    print(val)
end)

_add_word("INTERPRET", function ()
    while true do
        _call("WORD")
        _call("DUP")
        _call("FIND")
        local result = _pop_ds()
        if result == 0 then
            _call("NUMBER")
            _call("MAKE_LIT")
        else
            _call("DROP")
            _push_ds(result)
        end
        local word_fn = _pop_ds()
        word_fn()
    end
end)

-------------------------------------------------------------------------------
-- EXPERIMENTS
-------------------------------------------------------------------------------

-- (function()
--     _call("MEM_HERE")

--     _push_ds(".")
--     _call("FIND")
--     _call(",")
--     _push_ds("EXIT")
--     _call("FIND")
--     _call("PUSH_MEM")

--     _add_word("MY_WORD", _make_definition({
--         _find(".")
--     }))
-- end)()


_add_word("DUMP", function()
    for idx = #D_STACK,1,-1 do
        print(string.format("%d: %s", idx, tostring(D_STACK[idx])))
    end
end)

-------------------------------------------------------------------------------
-- MAIN LOOP
-------------------------------------------------------------------------------

_add_word("RUN_INTERACTIVE", function ()
    while true do
        _call("INTERPRET")
    end
end)

_call("RUN_INTERACTIVE")