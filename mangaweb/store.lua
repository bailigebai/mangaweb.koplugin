local Store = {}
Store.__index = Store

local SCHEMA = [[
CREATE TABLE IF NOT EXISTS favorites(
    site_id TEXT NOT NULL, comic_id TEXT NOT NULL, title TEXT NOT NULL,
    author TEXT, cover_url TEXT, detail_url TEXT, added_at INTEGER NOT NULL,
    PRIMARY KEY(site_id, comic_id)
);
CREATE TABLE IF NOT EXISTS categories(
    id INTEGER PRIMARY KEY, site_id TEXT NOT NULL, name TEXT NOT NULL,
    created_at INTEGER NOT NULL, UNIQUE(site_id, name)
);
CREATE TABLE IF NOT EXISTS favorite_categories(
    site_id TEXT NOT NULL, comic_id TEXT NOT NULL, category_id INTEGER NOT NULL,
    PRIMARY KEY(site_id, comic_id, category_id)
);
CREATE TABLE IF NOT EXISTS history(
    site_id TEXT NOT NULL, comic_id TEXT NOT NULL, title TEXT NOT NULL,
    author TEXT, cover_url TEXT, detail_url TEXT, page_index INTEGER NOT NULL,
    total_pages INTEGER NOT NULL, last_read_at INTEGER NOT NULL,
    PRIMARY KEY(site_id, comic_id)
);
]]

local function text(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function integer(value, fallback)
    value = tonumber(value)
    if not value then return fallback or 0 end
    return math.max(0, math.floor(value))
end

local function sqlite_database(sqlite, path)
    local connection = sqlite.open(path)
    return {
        exec = function(_, sql, args)
            if args and #args > 0 then
                local statement = connection:prepare(sql)
                statement:bind(unpack(args))
                statement:step()
                statement:clearbind():reset()
                statement:close()
                return true
            end
            connection:exec(sql)
            return true
        end,
        query = function(_, sql, args)
            local statement = connection:prepare(sql)
            if args and #args > 0 then statement:bind(unpack(args)) end
            local rows = {}
            for row in statement:rows() do rows[#rows + 1] = row end
            statement:close()
            return rows
        end,
        last_insert_id = function()
            return tonumber(connection:rowexec("SELECT last_insert_rowid()")) or 0
        end,
        close = function() connection:close() end,
    }
end

function Store:new(options)
    options = options or {}
    local database = options.database
    if not database then
        local sqlite = options.sqlite or require("lua-ljsqlite3/init")
        database = sqlite_database(sqlite, assert(options.path, "database path is required"))
    end
    local object = setmetatable({
        database = database,
        clock = options.clock or os.time,
    }, self)
    object.database:exec(SCHEMA)
    return object
end

function Store:_write(sql, args)
    return self.database:exec(sql, args or {})
end

function Store:_query(sql, args)
    return self.database:query(sql, args or {}) or {}
end

function Store:_transaction(operation)
    local begun, started = pcall(self._write, self, "begin")
    if not begun or started == false then return false, "storage_error" end
    local ok, result = pcall(operation)
    if not ok or result == false then
        pcall(self._write, self, "rollback")
        return false, "storage_error"
    end
    local committed, saved = pcall(self._write, self, "commit")
    if not committed or saved == false then
        pcall(self._write, self, "rollback")
        return false, "storage_error"
    end
    return true
end

function Store:add_favorite(record)
    record = record or {}
    return self:_write(
        "INSERT OR REPLACE INTO favorites (site_id,comic_id,title,author,cover_url,detail_url,added_at) VALUES (?,?,?,?,?,?,?)",
        { text(record.site_id), text(record.comic_id), text(record.title), text(record.author),
            text(record.cover_url), text(record.detail_url), integer(record.added_at, self.clock()) })
end

function Store:remove_favorite(site_id, comic_id)
    site_id, comic_id = text(site_id), text(comic_id)
    return self:_transaction(function()
        if self:_write("DELETE FROM favorite_categories WHERE site_id=? AND comic_id=?",
            { site_id, comic_id }) == false then return false end
        return self:_write("DELETE FROM favorites WHERE site_id=? AND comic_id=?",
            { site_id, comic_id })
    end)
end

function Store:is_favorite(site_id, comic_id)
    return #self:_query("SELECT 1 FROM favorites WHERE site_id=? AND comic_id=? LIMIT 1",
        { text(site_id), text(comic_id) }) > 0
end

function Store:list_favorites(site_id)
    local result = {}
    for _, row in ipairs(self:_query(
        "SELECT site_id,comic_id,title,author,cover_url,detail_url,added_at FROM favorites WHERE site_id=? ORDER BY added_at DESC",
        { text(site_id) })) do
        result[#result + 1] = { site_id = row[1], comic_id = row[2], title = row[3], author = row[4],
            cover_url = row[5], detail_url = row[6], added_at = row[7] }
    end
    return result
end

function Store:create_category(site_id, name)
    site_id, name = text(site_id), text(name)
    if name == "" then return nil, "empty_category" end
    if self:_write("INSERT INTO categories (site_id,name,created_at) VALUES (?,?,?)",
        { site_id, name, self.clock() }) == false then return nil, "storage_error" end
    local id = self.database.last_insert_id and self.database:last_insert_id() or 0
    return { id = id, site_id = site_id, name = name }
end

function Store:rename_category(site_id, category_id, name)
    name = text(name)
    if name == "" then return false, "empty_category" end
    return self:_write("UPDATE categories SET name=? WHERE site_id=? AND id=?",
        { name, text(site_id), integer(category_id) })
end

function Store:remove_category(site_id, category_id)
    site_id, category_id = text(site_id), integer(category_id)
    return self:_transaction(function()
        if self:_write("DELETE FROM favorite_categories WHERE site_id=? AND category_id=?",
            { site_id, category_id }) == false then return false end
        return self:_write("DELETE FROM categories WHERE site_id=? AND id=?",
            { site_id, category_id })
    end)
end

function Store:list_categories(site_id)
    local result = {}
    for _, row in ipairs(self:_query(
        "SELECT id,name,created_at FROM categories WHERE site_id=? ORDER BY name",
        { text(site_id) })) do
        result[#result + 1] = { id = row[1], site_id = text(site_id), name = row[2], created_at = row[3] }
    end
    return result
end

function Store:category_for(site_id, comic_id)
    local row = self:_query(
        "SELECT category_id FROM favorite_categories WHERE site_id=? AND comic_id=? ORDER BY category_id LIMIT 1",
        { text(site_id), text(comic_id) })[1]
    return row and tonumber(row[1]) or nil
end

function Store:assign_category(site_id, comic_ids, category_id)
    site_id = text(site_id)
    if type(comic_ids) ~= "table" or #comic_ids == 0 then return false, "empty_selection" end
    if category_id ~= nil then
        category_id = integer(category_id)
        if category_id == 0 or #self:_query(
            "SELECT 1 FROM categories WHERE site_id=? AND id=? LIMIT 1",
            { site_id, category_id }) == 0 then return false, "unknown_category" end
    end
    local ids, seen = {}, {}
    for _, value in ipairs(comic_ids) do
        local comic_id = text(value)
        if comic_id == "" or not self:is_favorite(site_id, comic_id) then
            return false, "not_favorite"
        end
        if not seen[comic_id] then
            seen[comic_id] = true
            ids[#ids + 1] = comic_id
        end
    end
    return self:_transaction(function()
        for _, comic_id in ipairs(ids) do
            if self:_write("DELETE FROM favorite_categories WHERE site_id=? AND comic_id=?",
                { site_id, comic_id }) == false then return false end
            if category_id ~= nil and self:_write(
                "INSERT INTO favorite_categories (site_id,comic_id,category_id) VALUES (?,?,?)",
                { site_id, comic_id, category_id }) == false then return false end
        end
        return true
    end)
end

function Store:list_category_items(site_id, category_id)
    local result = {}
    for _, row in ipairs(self:_query(
        "SELECT f.site_id,f.comic_id,f.title,f.author,f.cover_url,f.detail_url,f.added_at FROM favorites f INNER JOIN favorite_categories c ON c.site_id=f.site_id AND c.comic_id=f.comic_id WHERE c.site_id=? AND c.category_id=? ORDER BY f.added_at DESC",
        { text(site_id), integer(category_id) })) do
        result[#result + 1] = { site_id = row[1], comic_id = row[2], title = row[3], author = row[4],
            cover_url = row[5], detail_url = row[6], added_at = row[7] }
    end
    return result
end

local function history_record(row)
    if not row then return nil end
    return { site_id = row[1], comic_id = row[2], title = row[3], author = row[4], cover_url = row[5],
        detail_url = row[6], page_index = row[7], total_pages = row[8], last_read_at = row[9] }
end

function Store:save_history(record)
    record = record or {}
    return self:_write(
        "INSERT OR REPLACE INTO history (site_id,comic_id,title,author,cover_url,detail_url,page_index,total_pages,last_read_at) VALUES (?,?,?,?,?,?,?,?,?)",
        { text(record.site_id), text(record.comic_id), text(record.title), text(record.author),
            text(record.cover_url), text(record.detail_url), integer(record.page_index, 1),
            integer(record.total_pages, 1), integer(record.last_read_at, self.clock()) })
end

function Store:get_history(site_id, comic_id)
    return history_record(self:_query(
        "SELECT site_id,comic_id,title,author,cover_url,detail_url,page_index,total_pages,last_read_at FROM history WHERE site_id=? AND comic_id=? LIMIT 1",
        { text(site_id), text(comic_id) })[1])
end

function Store:list_history(site_id)
    local result = {}
    for _, row in ipairs(self:_query(
        "SELECT site_id,comic_id,title,author,cover_url,detail_url,page_index,total_pages,last_read_at FROM history WHERE site_id=? ORDER BY last_read_at DESC",
        { text(site_id) })) do
        result[#result + 1] = history_record(row)
    end
    return result
end

function Store:remove_history(site_id, comic_id)
    return self:_write("DELETE FROM history WHERE site_id=? AND comic_id=?",
        { text(site_id), text(comic_id) })
end

function Store:close()
    if self.database.close then return self.database:close() end
    return true
end

return Store
