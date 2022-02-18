--- Generates tables of hottest / lines symbols for various occasions.

local callgraph = require("perfanno.callgraph")
local treesitter = require("perfanno.treesitter")
local config = require("perfanno.config")
local util = require("perfanno.util")

local M = {}

--- Generates a table entry for a given file / line number with a certain event count.
-- @param file File in the call graph. Can be "symbol" which means that we do not know the file and
--        the next parameter should be interpreted as an arbitrary symbol instead.
-- @param linenr Line number in the file (or symbol, see above).
-- @param count Total count of the event.
-- @return Table with entries for symbol, file, line number, and event count.
local function entry_from_line(file, linenr, count)
    if file == "symbol" then
        return {
            symbol = linenr,
            file = nil,  -- TODO: maybe could have symbols with file but no line?
            linenr = nil,
            count = count
        }
    else
        return {
            symbol = nil,  -- TODO: we might have this information
            file = file,
            linenr = linenr,
            count = count
        }
    end
end

--- Generates a table entry for a given symbol (with known location) in the call graph.
-- @param cg Call graph to use.
-- @param file File that contains the symbol.
-- @param symbol Name of the symbol.
-- @return Table with entries for symbol, file, line number, and event count.
local function entry_from_symbol(cg, file, symbol)
    return {
        symbol = symbol,
        file = file,
        linenr = cg.symbols[file][symbol].min_line,
        count = cg.symbols[file][symbol].count
    }
end

--- Generates table of hottest lines for a given event.
-- @param event Event to use.
-- @return tab, count where tab is a table of entries as generated by entry_from_line and
--         entry_from_symbol and count is the total event count for the given event.
function M.hottest_lines_table(event)
    local entries = {}
    local cg = callgraph.callgraphs[event]

    for file, file_tbl in pairs(cg.node_info) do
        for linenr, node_info in pairs(file_tbl) do
            if config.should_display(node_info.count, cg.total_count) then
                table.insert(entries, entry_from_line(file, linenr, node_info.count))
            end
        end
    end

    table.sort(entries, function(e1, e2)
        return e1.count > e2.count
    end)

    return entries
end

--- Generates table of hottest symbols for a given event.
-- @param event Event to use.
-- @return tab, count where tab is a table of entries as generated by entry_from_line and
--         entry_from_symbol and count is the total event count for the given event.
function M.hottest_symbols_table(event)
    local entries = {}
    local cg = callgraph.callgraphs[event]

    for file, syms in pairs(cg.symbols) do
        for sym, info in pairs(syms) do
            if config.should_display(info.count, cg.total_count) then
                table.insert(entries, entry_from_symbol(cg, file, sym))
            end
        end
    end

    for sym, info in pairs(cg.node_info.symbol) do
        if config.should_display(info.count, cg.total_count) then
            table.insert(entries, entry_from_line("symbol", sym, info.count))
        end
    end

    table.sort(entries, function(e1, e2)
        return e1.count > e2.count
    end)

    return entries, cg.total_count
end

--- Generates table of hottest callers of a given section of a file.
-- @param event Event to use.
-- @param file File that contains the section.
-- @param line_begin Beginning of the section (1-indexed, inclusive).
-- @param line_end End of the section (1-indexed, inclusive).
-- @return tab, count where tab is a table of entries as generated by entry_from_line and
--         entry_from_symbol and count is the total event count for the lines in the given section.
local function hottest_callers_table(event, file, line_begin, line_end)
    local lines = {}
    local total_count = 0
    local cg = callgraph.callgraphs[event]

    for linenr, node_info in pairs(cg.node_info[file]) do
        if linenr >= line_begin and linenr <= line_end then
            table.insert(lines, {file, linenr})
            total_count = total_count + node_info.count
        end
    end

    local in_counts = callgraph.merge_in_counts(event, lines)
    local entries = {}

    for in_file, file_tbl in pairs(in_counts) do
        for in_line, count in pairs(file_tbl) do
            if config.format(count, total_count) then
                table.insert(entries, entry_from_line(in_file, in_line, count))
            end
        end
    end

    table.sort(entries, function(e1, e2)
        return e1.count > e2.count
    end)

    return entries, total_count
end

--- Gets the file underlying the current buffer in a canonical format.
-- @return File in canonical, full path format (should agree with call graph file entries).
local function current_canonical_file()
    local file = vim.fn.expand("%", ":p")
    return vim.loop.fs_realpath(file)
end

--- Generates table of hottest callers of the function cointainig the cursor.
-- @param event Event to use.
-- @return Table of entries as generated by entry_from_line and entry_from_symbol.
function M.hottest_callers_function_table(event)
    local file = current_canonical_file()

    if not file then
        vim.notify("Could not find current file!")
        return nil
    end

    local line_begin, line_end = treesitter.get_function_lines()

    if line_begin and line_end then
        return hottest_callers_table(event, file, line_begin, line_end)
    else
        vim.notify("Could not find surrounding function!")
    end
end

--- Generates table of hottest callers of the current visual selection.
-- @param event Event to use.
-- @return Table of entries as generated by entry_from_line and entry_from_symbol.
function M.hottest_callers_selection_table(event)
    local file = current_canonical_file()

    if not file then
        vim.notify("Could not find current file!")
        return nil
    end

    local line_begin, _, line_end, _ = util.visual_selection_range()

    if line_begin and line_end then
        return hottest_callers_table(event, file, line_begin, line_end)
    else
        vim.notify("Could not get visual selection!")
    end
end

--- Jumps to the file location of a table entry.
-- @param entry Entry as generated by entry_from_line or entry_from_symbol.
local function go_to_entry(entry)
    if entry and entry.file and vim.fn.fileisreadable(entry.file) then
        -- TODO: Isn't there a way to do this via the lua API??
        if entry.linenr then
            vim.cmd(":edit +" .. entry.linenr .. " " .. vim.fn.fnameescape(entry.file))
        else
            vim.cmd(":edit " .. vim.fn.fnameescape(entry.file))
        end
    end
end

--- Nicely formats table entry according to the current format.
-- @param entry Entry to format.
-- @param total_count Total count for the event (e.g. relative to a selection).
-- @return String in format "{count} {symbol} at {location}".
function M.format_entry(entry, total_count)
    local display = config.format(entry.count, total_count)

    if entry.file then
        local path = vim.fn.fnamemodify(entry.file, ":~:.")

        if entry.linenr then
            path = path .. ":" .. entry.linenr
        end

        if entry.symbol then
            display = display .. " " .. entry.symbol .. " at " .. path
        else
            display = display .. " " .. path
        end
    elseif entry.symbol then
        display = display .. " " .. entry.symbol
    else
        display = display .. " ??"
    end

    return display
end

--- Helper function that creates a select dialogue for a given find hottest table function.
-- @param event Event to use.
-- @param prompt Prompt to be displayed in the dialogue.
-- @param table_fn Function that takes an event and generates both a table of entries for hot lines
--        as well as a total event count hottest_lines_table or hottest_symbols_table.
local function find_hottest(event, prompt, table_fn)
    assert(callgraph.is_loaded(), "Callgraph is not loaded!")
    event = event or config.selected_event
    assert(callgraph.callgraphs[event], "Invalid event!")

    local entries, total_count = table_fn(event)

    local opts = {
        prompt = prompt,
        format_item = function(entry)
            return M.format_entry(entry, total_count)
        end,
        kind = "File"
    }

    vim.ui.select(entries, opts, go_to_entry)
end

--- Displays select dialogue to find the hottest lines in the project.
-- @param event Event to use.
function M.find_hottest_lines(event)
    find_hottest(event, "Hottest lines: ", M.hottest_lines_table)
end

--- Displays select dialogue to find the hottest symbols (functions) in the project.
-- @param event Event to use.
function M.find_hottest_symbols(event)
    find_hottest(event, "Hottest symbols: ", M.hottest_symbols_table)
end

--- Displays select dialogue to find the hottest callers of the function containing the cursor.
-- @param event Event to use.
function M.find_hottest_callers_function(event)
    find_hottest(event, "Hottest callers: ", M.hottest_callers_function_table)
end

--- Displays select dialogue to find the hottest callers of the current visual selection.
-- @param event Event to use.
function M.find_hottest_callers_selection(event)
    find_hottest(event, "Hottest callers: ", M.hottest_callers_selection_table)
end

return M
