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

    Why is indirect threaded code important? Because it provides some
    context about from where native code is invoked. Let's look at an
    example: we want to create a variable named MYVAR.
    In forth this means we need a word that, when executed, puts the address
    of our variable on the stack.
    Whatever native code will in the end put the address of the variable on
    the stack needs to know this address.

    In direct threaded code, knowing the address of the variable is a bit
    tricky. The implementation will look something like this

    ```lua
    function put_variable()
        ... code to put variable address on the stack ...
        return next()
    end
    ...
    define_variable("MYVAR")
    ```
    `put_variable` puts the address on the stack and then jumps to (instead
    of calling, because of tail call support) the code triggering the
    execution of the next word. `MYVAR` should call out to put_variable such
    that put_variable puts the address of the variable storage on the stack.

    A higher level word that uses `put_variable` could be defined like this:
    `define_word("MYWORD", { some_word, MYVAR, some_other_word })`.
    In direct threaded code, MYVAR directly points to some executable code.

    Now let's look at what information `put_variable` might have available to
    figure out what address MYVAR has:
    - Data stack: no, because putting the variable's address on the data stack
        is the problem we're trying to solve
    - Return stack: no, manipulation of the return stack across word boundaries
        is limited to starting and finishing word execution
    - Call origin: no, the call origin here is MYWORD, which does not give us
        any information about MYVAR

    Hence, direct threaded code needs some other, out-of-band information to
    determine the correct address to put on the stack for MYVAR. This can be
    done e.g. by creating a closure for each variable and having the word point
    to this closure directly. While this is easy to implement in lua, it seems
    wasteful and complicated to implement for bare-bones FORTH implementations
    written in assembly.

    Indirect threaded code elegantly solves this issue. Let's look again at
    how `MYWORD` is defined:
    `define_word("MYWORD", { some_word, MYVAR , some_other_word })`.
    Now, MYVAR does not point to executable code directly, it points to a
    location in memory (in lua an array offset) that contains executable code.
    So after calling `define_variable("MYVAR")`, our "memory" array will look
    something like this:
    ```
    |  cell x-1: ... | cell x: put_variable | cell x+1: ... |
    ```
    and `MYVAR` will contain the number `x`. Now when we call put_variable
    as part of some arbitrary word (`MYWORD`), the call origin is now `x`, which
    is unique to MYVAR and can be used to determine the correct address to put
    on the stack. In practice, that address will simply be x+1 and that cell
    will also provide the storage for the variable. So the memory array will
    look like this:
    ```
    |  cell x-1: ... | cell x: put_variable | cell x+1: MYVAR | cell x+2: ...  |
    ```

    This trick is used for multiple purposes (word definitions, variable
    definitions, branches, encoding literals) and because of its simplicit and
    elegance, indirect threaded code is the execution model of choice for forth.

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

local _codeword_to_name = {}
local function _try_resolve_codeword(code_word)
    local name = _codeword_to_name[code_word]
    return name
end
local function _resolve_codeword(code_word)
    return _try_resolve_codeword(code_word) or "N/A"
end

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
    _codeword_to_name[_cfa(offset)] = name
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

-- Interpreter for indirect threaded code
-- Code is expected to call a continuation instead
-- of returning. _next's continuatino is the code
-- word to execute. This code word's continuation
-- then is whatever was passed to _next, which more
-- than likely is _next again.
local function _next(cont)
    CODE_WORD = MEM[NEXT_INST]
    NEXT_INST = NEXT_INST + 1
    return MEM[CODE_WORD](cont)
end

-- A neat side-effect of passing the continuation
-- to native words is that it allows native words
-- to call native words themselves with this _nop
-- continuation that simply stops instead of
-- continuing to interpret forth code (while still
-- inside the execution of a native word).
local function _nop(nop)
end

local function _start_vm(code_word)
    NEXT_INST = nil
    CODE_WORD = code_word
    MEM[CODE_WORD](_next)
end

--------------------------------------
-- WORD DEFINITIONS

-- All of these operate on the data/return stack and can
-- be used from lua (via the _* functions) or from forth
-- via the REPL or the pointer to code worde returned by
-- _add_word

--------------------------------------

local function DOCOL(cont)
    table.insert(RSTACK, NEXT_INST)
    NEXT_INST = CODE_WORD + 1
    return cont(cont)
end

local function _EXIT(cont)
    NEXT_INST = table.remove(RSTACK)
    return cont(cont)
end
local EXIT = _add_word("EXIT", {}, _EXIT)

-- This is a bit awkward, we need a total of three functions
-- to call forth words from native words:
-- - STOP ensures we don't end on a tailcall to _next and jumps back to the native word
-- - RUN to provide the regular data layout expected by the interpreter. The data field
--    is updated to point to the code word of the forth entry we want to call
-- - _run to actually set up rstack, next_inst, and kick off execution
local function _STOP(cont)
    NEXT_INST = table.remove(RSTACK)
    -- CONTINUATION IS *NOT* CALLED
end
local STOP = _add_word("STOP", {}, _STOP)
local RUN = _add_word("RUN", {}, DOCOL, { 0, STOP })
local function _run(code_word)
    table.insert(RSTACK, NEXT_INST)
    MEM[RUN+1] = code_word
    NEXT_INST = RUN+1
    return _next(_next)
end

local function VARADDR(cont)
    _pushds(CODE_WORD + 1)
    return cont(cont)
end

-- ( -- n) n = number of elements on the stack before DEPTH call
local function _DEPTH(cont)
    _pushds(#DSTACK)
    return cont(cont)
end
local DEPTH = _add_word("DEPTH", {}, _DEPTH)

local function _CLEARDSTACK(cont)
    DSTACK = {}
    return cont(cont)
end
local CLEARDSTACK = _add_word("CLEAR-DSTACK", {}, _CLEARDSTACK)

local function _CLEARRSTACK(cont)
    RSTACK = {}
    return cont(cont)
end
local CLEARRSTACK = _add_word("CLEAR-RSTACK", {}, _CLEARRSTACK)

-- ( A -- A A )
local function _DUP(cont)
    local val = _popds()
    _pushds(val)
    _pushds(val)
    return cont(cont)
end
local DUP = _add_word("DUP", {}, _DUP)

-- ( A B C -- B C A )
local function _ROT(cont)
    local c = _popds()
    local b = _popds()
    local a = _popds()
    _pushds(b)
    _pushds(c)
    _pushds(a)
    return cont(cont)
end
local ROT = _add_word("ROT", {}, _ROT)

-- ( A -- )
local function _DROP(cont)
    _popds()
    return cont(cont)
end
local DROP = _add_word("DROP", {}, _DROP)

-- ( A B -- B A )
local function _SWAP(cont)
    local v1 = _popds()
    local v2 = _popds()
    _pushds(v1)
    _pushds(v2)
    return cont(cont)
end
local SWAP = _add_word("SWAP", {}, _SWAP)

-- ( A B -- A B A )
local function _OVER(cont)
    local v1 = _popds()
    local v2 = _popds()
    _pushds(v2)
    _pushds(v1)
    _pushds(v2)
    return cont(cont)
end
local OVER = _add_word("OVER", {}, _OVER)

-- ( A B -- A B A B )
local function _TWODUP(cont)
    local v1 = _popds()
    local v2 = _popds()
    _pushds(v2)
    _pushds(v1)
    _pushds(v2)
    _pushds(v1)
    return cont(cont)
end
local TWODUP = _add_word("2DUP", {}, _TWODUP)

-- ( A B -- )
local function _TWODROP(cont)
    _popds()
    _popds()
    return cont(cont)
end
local TWODROP = _add_word("2DROP", {}, _TWODROP)

-- ( A B C D -- C D A B )
local function _TWOSWAP(cont)
    local v1 = _popds()
    local v2 = _popds()
    local v3 = _popds()
    local v4 = _popds()
    _pushds(v2)
    _pushds(v1)
    _pushds(v4)
    _pushds(v3)
    return cont(cont)
end
local TWOSWAP = _add_word("2SWAP", {}, _TWOSWAP)

local function _LIT(cont)
    local val = MEM[NEXT_INST]
    table.insert(DSTACK, val)
    NEXT_INST = NEXT_INST + 1
    return cont(cont)
end
local LIT = _add_word("LIT", {}, _LIT)
local LITSTRING = _add_word("LITSTRING", {}, _LIT)

local function _COMMA(cont)
    MEM[#MEM+1] = _popds()
    return cont(cont)
end
local COMMA = _add_word(",", {}, _COMMA)

-- compile-time: ( x -- )
-- appends run-time: ( -- x )
local LITERAL = _add_word("LITERAL", { immediate = true }, DOCOL, { LIT, LIT, COMMA, COMMA, EXIT })

local LATEST = _add_word("LATEST", {}, DOCOL, {LIT, _LATEST_ADDR, EXIT})
local STATE = _add_word("STATE", {}, DOCOL, {LIT, _STATE_ADDR, EXIT})

local function _FETCH(cont)
    local offset = _popds()
    _pushds(MEM[offset])
    return cont(cont)
end
local FETCH = _add_word("@", {}, _FETCH)

local function _STORE(cont)
    local offset = _popds()
    local value = _popds()
    MEM[offset] = value
    return cont(cont)
end
local STORE = _add_word("!", {}, _STORE)

local function _HERE(cont)
    _pushds(#MEM + 1)
    return cont(cont)
end
local HERE = _add_word("HERE", {}, _HERE)

local function _ALLOT(cont)
    local new_size = #MEM + _popds()
    while #MEM < new_size do
        table.insert(MEM, 0)
    end
    while #MEM > new_size do
        table.remove(MEM)
    end
    return cont(cont)
end
local ALLOT = _add_word("ALLOT", {}, _ALLOT)

local function _FIND(cont)
    local name = string.upper(_popds())
    local offset = MEM[_LATEST_ADDR]
    while offset ~= 0 do
        if MEM[offset + 1] == name then
            _pushds(offset)
            return cont(cont)
        end
        offset = MEM[offset]
    end
    _pushds(0)
    return cont(cont)
end
local FIND = _add_word("FIND", {}, _FIND)

local function _CFA(cont)
    local offset = _popds()
    _pushds(_cfa(offset))
    return cont(cont)
end
local CFA = _add_word(">CFA", {}, _CFA)

local function _ADD(cont)
    local v1 = _popds()
    local v2 = _popds()
    _pushds(v1 + v2)
    return cont(cont)
end
local ADD = _add_word("+", {}, _ADD)

local function _SUB(cont)
    local v1 = _popds()
    local v2 = _popds()
    _pushds(v2 - v1)
    return cont(cont)
end
local SUB = _add_word("-", {}, _SUB)

local function _EQ(cont)
    local v1 = _popds()
    local v2 = _popds()
    if v2 == v1 then
        _pushds(1)
    else
        _pushds(0)
    end
    return cont(cont)
end
local EQ = _add_word("=", {}, _EQ)

local function _NOT(cont)
    local val = _popds()
    _pushds(val == 0 or not val)
    return cont(cont)
end
local NOT = _add_word("NOT", {}, _NOT)

local NEQ = _add_word("!=", {}, DOCOL, { EQ, NOT, EXIT })

local INC = _add_word("+1", {}, DOCOL, {LIT, 1, ADD, EXIT})
local DEC = _add_word("-1", {}, DOCOL, {LIT, 1, SUB, EXIT})

local function _ISIMMEDIATE(cont)
    local entry_offset = _popds()
    local flags = MEM[entry_offset + 2]
    _pushds(flags.immediate or false)
    return cont(cont)
end
local ISIMMEDIATE = _add_word("ISIMMEDIATE", {}, _ISIMMEDIATE)

local function _IMMEDIATE(cont)
    local entry_offset = MEM[_LATEST_ADDR]
    local flags = MEM[entry_offset + 2]
    flags.immediate = true
    return cont(cont)
end
local IMMEDIATE = _add_word("IMMEDIATE", { immediate = true }, _IMMEDIATE)

local function _BRANCH(cont)
    NEXT_INST = NEXT_INST + MEM[NEXT_INST]
    return cont(cont)
end
local BRANCH = _add_word("BRANCH", {}, _BRANCH)

local function _ZBRANCH(cont)
    local test = _popds()
    if test == 0 or test == false then
        NEXT_INST = NEXT_INST + MEM[NEXT_INST]
    else
        NEXT_INST = NEXT_INST + 1
    end
    return cont(cont)
end
local ZBRANCH = _add_word("0BRANCH", {}, _ZBRANCH)

-- ( ch1 ch2 ... chn n -- str)
-- This is terrible, but using MEM as scratch requires mutable HERE
local function _MAKESTRING(cont)
    local count = _popds()
    local buf = {}
    for _ = count,1,-1 do
        table.insert(buf, _popds())
    end
    _pushds(string.reverse(table.concat(buf)))
    return cont(cont)
end
local MAKESTRING = _add_word("MAKESTRING", {}, _MAKESTRING)

-- ( n var - )
local ADDSTORE = _add_word("+!", {}, DOCOL, {
    SWAP, OVER, FETCH, ADD, SWAP, STORE, EXIT
})

-- ( n var - )
local SUBSTORE = _add_word("-!", {}, DOCOL, {
    SWAP, OVER, FETCH, SUB, SWAP, STORE, EXIT
})

local function _DOT(cont)
    io.write(string.format("%d", _popds()))
    return cont(cont)
end
local DOT = _add_word(".", {}, _DOT)

local function _EMIT(cont)
    io.write(string.format("%c", _popds()))
    return cont(cont)
end
local EMIT = _add_word("EMIT", {}, _EMIT)

local CR = _add_word("CR", {}, DOCOL, { LIT, 13, EXIT })
local LF = _add_word("LF", {}, DOCOL, { LIT, 10, EXIT })

local function _TELL(cont)
    io.write(_popds())
    io.flush()
    return cont(cont)
end
local TELL = _add_word("TELL", {}, _TELL)

local INIT_LINES = {}
local _STDIN_BUFFER = nil
local _STDIN_POS = nil

local function _PROMPT(cont)
    if #INIT_LINES > 0 then
        _STDIN_BUFFER = table.remove(INIT_LINES, 1)
        _STDIN_POS = 1
        return
    end
    io.write(">>> ")
    io.flush()
    _STDIN_BUFFER = io.read("*line")
    if not _STDIN_BUFFER then
        os.exit(0)
    end
    _STDIN_BUFFER = _STDIN_BUFFER .. '\n'
    _STDIN_POS = 1
    return cont(cont)
end

local function _KEY(cont)
    if not _STDIN_BUFFER or _STDIN_POS > #_STDIN_BUFFER then
        _PROMPT(_nop)
    end
    _pushds(string.sub(_STDIN_BUFFER, _STDIN_POS, _STDIN_POS))
    _STDIN_POS = _STDIN_POS + 1
    return cont(cont)
end
KEY = _add_word("KEY", {}, _KEY)

local function _ISWS(cont)
    local ch = _popds()
    _pushds(ch == ' ' or ch == '\n' or ch == '\t')
    return cont(cont)
end
ISWS = _add_word("ISWS", {}, _ISWS)

local WORD = _add_word("WORD", {}, DOCOL,{
    -- counter for how number chars we have on the stack
    LIT, 0,

    KEY,
    -- if not whitespace, escape loop
    DUP, ISWS, ZBRANCH, 4,
    -- else drop char and repeat
    DROP, BRANCH, -7,

    -- build buffer
    SWAP, INC,
    KEY, DUP, ISWS,
    ZBRANCH, -6,

    DROP, MAKESTRING,
    EXIT
})

local CH_QUOTE = _add_word("'\"'", {}, DOCOL, { LITSTRING, "\"", EXIT })

--[[
    : S"
        0
        BEGIN
            KEY
            DUP '"' !=
        WHILE
            SWAP +1
        REPEAT
        DROP
        MAKESTRING
    ;
]]
local SQUOTE = _add_word("S\"", { }, DOCOL, {
    LIT, 0, KEY, DUP, CH_QUOTE, NEQ, ZBRANCH, 5, SWAP, INC, BRANCH, -9, DROP, MAKESTRING, EXIT
})

-- This project uses the specification for ticks from https://forth-standard.org/
-- which differs from the one in jonesforth
-- : ' WORD FIND DUP IF >CFA THEN ;
local TICK = _add_word("'", { }, DOCOL, { WORD, FIND, DUP, ZBRANCH, 2, CFA, EXIT })
-- : ['] IMMEDIATE ' POSTPONE LITERAL ;
local CTICK = _add_word("[']", { immediate = true }, DOCOL, { TICK, LITERAL, EXIT })

local function _NUMBER(cont)
    local value = _popds()
    local number = tonumber(value)
    if not number then
        _pushds(0)
        _pushds(0)
        return cont(cont)
    end
    _pushds(number)
    _pushds(1)
    return cont(cont)
end
local NUMBER = _add_word("NUMBER", {}, _NUMBER)

local function _LPARENS(cont)
    local word
    repeat
        _run(WORD)
        word = _popds()
    until word == ")"
    return cont(cont)
end
local LPARENS = _add_word("(", { immediate = true }, _LPARENS)

local function _DUMP(cont)
    for idx = #DSTACK,1,-1 do
        print(string.format("%d: %s", idx, tostring(DSTACK[idx])))
    end
    return cont(cont)
end
local DUMP = _add_word("DUMP", {}, _DUMP)

local LBRAC = _add_word("[", { immediate = true }, DOCOL, { LIT, 0, STATE, STORE, EXIT })
local RBRAC = _add_word("]", { immediate = true }, DOCOL, { LIT, 1, STATE, STORE, EXIT })

local function _CREATE(cont)
    local name = _popds()
    local flags = {}
    _create(name, flags)
    return cont(cont)
end
local CREATE = _add_word("CREATE", {}, _CREATE)

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

-- ( addr -- str )
local function _FINDNAME(cont)
    local code_word = _popds()
    _pushds(_resolve_codeword())
    return cont(cont)
end
local FINDNAME = _add_word("FINDNAME", {}, _FINDNAME)

-- ( addr -- )
local function _DECOMPILE(cont)
    _run(WORD)
    _run(FIND)
    local entry = _popds()
    if entry == 0 then
        io.write("Unable to find word\n")
        return cont(cont)
    end
    io.write(string.format(": %s ", MEM[entry + 1]))
    if MEM[entry+3] ~= DOCOL then
        io.write("[native word]\n")
        return cont(cont)
    end
    local data_fields = {
        [LIT] = 1,
        [LITSTRING] = 1,
        [BRANCH] = 1,
        [ZBRANCH] = 1,
    }
    local pos = entry+4
    repeat
        io.write(_resolve_codeword(MEM[pos]) .. " ")
        local dfields = data_fields[MEM[pos]] or 0

        for _ = 1,dfields,1 do
            pos = pos + 1
            local numeric = MEM[pos]
            local word = _try_resolve_codeword(numeric)
            if word then
                io.write(string.format("%s/%s ", numeric, word))
            else
                io.write(string.format("%s ", numeric))
            end
        end
        pos = pos + 1
    until MEM[pos] == EXIT or MEM[pos] == nil
    io.write(_resolve_codeword(MEM[pos]) .. " ;")
    if type(MEM[entry+2]) == "table" and MEM[entry+2].immediate then
        io.write(" IMMEDIATE")
    end
    io.write("\n")
    return cont(cont)
end
local DECOMPILE = _add_word("DECOMPILE", {}, _DECOMPILE)

local function _DUMPMEM(cont)
    local length = _popds()
    local copy = {}
    for i = #MEM-length,#MEM,1 do
        table.insert(copy, MEM[i])
    end
    print(_format_data(copy))
    return cont(cont)
end
local DUMPMEM = _add_word("DUMPMEM", {}, _DUMPMEM)

local function _INTERPRET(cont)
    _run(WORD)
    _DUP(_nop)
    _FIND(_nop)
    local entry = _popds()
    if entry == 0 then
        _NUMBER(_nop)
        local success = _popds()
        if success == 0 or success == false then
            _pushds("Error: not a word or number\n")
            _TELL(_nop)
            _DROP(_nop)
            return cont(cont)
        end
        if MEM[_STATE_ADDR] == 1 then -- compile
            _pushds(LIT)
            _COMMA(_nop)
            _COMMA(_nop)
        end
    else
        _DROP(_nop)
        _pushds(entry)
        if MEM[_STATE_ADDR] == 0 then -- immediate
            _CFA(_nop)
            CODE_WORD = _popds()
            return MEM[CODE_WORD](cont)
        else
            _DUP(_nop)
            _ISIMMEDIATE(_nop)
            local is_immediate = _popds()
            _CFA(_nop)
            if is_immediate then
                CODE_WORD = _popds()
                return MEM[CODE_WORD](cont)
            else
                _COMMA(_nop)
            end
        end
    end
    return cont(cont)
end
local INTERPRET = _add_word("INTERPRET", {}, _INTERPRET)

QUIT = _add_word("QUIT", {}, DOCOL, { CLEARRSTACK, INTERPRET, BRANCH, -2, EXIT })
ABORT = _add_word("ABORT", {}, DOCOL, { CLEARDSTACK, QUIT })

MYSUB = _add_word("MYSUB", {}, DOCOL, {LIT, 1337, DOT, EXIT})
MYPROGRAM = _add_word("MYPROGRAM", {}, DOCOL, {LITSTRING, "Some String\n", TELL, LIT, 2, LIT, 3, MYSUB, LIT, 4, DUMP, EXIT})
TESTVAR = _add_word("TESTVAR", {}, VARADDR, {0})
BRANCHTEST = _add_word("BRANCHTEST", {}, DOCOL, {LIT, 1, BRANCH, 3, LIT, 2, LIT, 3, DUMP, EXIT})

-- : IF ( prepare 0BRANCH + ARG ) ['] 0BRANCH , HERE 0 , ; IMMEDIATE
_add_word("IF", { immediate = true }, DOCOL, { LIT, ZBRANCH, COMMA, HERE, LIT, 0, COMMA, EXIT })

--[[
    : ELSE
        ( update 0BRANCH ) DUP HERE SWAP - 2 + SWAP !
        ( prepare BRANCH ) ['] BRANCH , HERE 0 ,
    ; IMMEDIATE
]]
_add_word("ELSE", { immediate = true }, DOCOL, { DUP, HERE, SWAP, SUB, LIT, 2, ADD, SWAP, STORE, LIT, BRANCH, COMMA, HERE, LIT, 0, COMMA, EXIT })

-- : THEN ( update 0BRANCH/BRANCH ) DUP HERE SWAP - SWAP ! ; IMMEDIATE
_add_word("THEN", { immediate = true }, DOCOL, { DUP, HERE, SWAP, SUB, SWAP, STORE, EXIT })

--[[
    : BEGIN ( C: -- loop ) HERE ; IMMEDIATE
    Can be used as either:
    BEGIN ... condition UNTIL
    or
    BEGIN ... condition WHILE ... REPEAT
]]
_add_word("BEGIN", { immediate = true }, DOCOL, { HERE, EXIT })

-- : UNTIL ( jump back if false ) ['] 0BRANCH , HERE -  , ; IMMEDIATE
_add_word("UNTIL", { immediate = true }, DOCOL, { LIT, ZBRANCH, COMMA, HERE, SUB, COMMA, EXIT })

--[[
    : WHILE ( C: loop -- loop after )
        ( prepare branch for exit ) ['] 0BRANCH , HERE
        ( fill dummy value ) 0 ,
    ; IMMEDIATE
]]
_add_word("WHILE", { immediate = true }, DOCOL, {
    LIT, ZBRANCH, COMMA, HERE, LIT, 0, COMMA, EXIT
})

--[[
    : REPEAT ( C: loop after -- )
        ( add branch to loop start )
        ['] BRANCH , SWAP HERE - ,
        ( backfill 0BRANCH from WHILE )
        DUP HERE SWAP - SWAP !
    ; IMMEDIATE
    Testing:
    : MYWHILETEST 0 BEGIN DUP 10 != WHILE +1 REPEAT ;
    T{ MYWHILETEST -> 10 }
]]
_add_word("REPEAT", { immediate = true }, DOCOL, {
    LIT, BRANCH, COMMA, SWAP, HERE, SUB, COMMA, DUP, HERE, SWAP, SUB, SWAP, STORE, EXIT
})

table.insert(INIT_LINES, ": MYIFTEST 0 != IF 23 . LF EMIT THEN ; ")
table.insert(INIT_LINES, ": MYIFELSETEST 0 != IF 23 ELSE 42 THEN . LF EMIT ; ")
table.insert(INIT_LINES, ": MYREPEATTEST 0 BEGIN +1 DUP 100 = UNTIL . LF EMIT ; ")

_start_vm(QUIT)