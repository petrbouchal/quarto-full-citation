-- full-citation.lua
-- Pandoc/Quarto Lua filter: inline full formatted citations + PDF attachments.
--
-- Strategy:
--   Quarto's user filters run BEFORE pandoc's own citeproc pass.
--   We therefore call pandoc.utils.citeproc() ourselves, extract formatted
--   references from the resulting #refs div, do substitutions, then clear
--   bibliography metadata so pandoc's subsequent citeproc pass is a no-op.
--
-- Div syntax:
--   :::{.full-citation}
--   [@citekey]
--   :::
--
--   :::{.full-citation ref="citekey"}   ← explicit key (needs nocite or inline use)
--   :::
--
-- Front-matter options:
--   full-citation-suppress-bibliography: true   drop the trailing #refs div
--   full-citation-attachments: false            skip PDF copy + [PDF] link
--                                               ([online] links still added)
--   full-citation-all: true                     expand every [@key] citation
--                                               to a full citation inline

local refs        = {}   -- key  →  list of Block
local bib_entries = {}   -- key  →  { path, url, bib_dir, bib_name }


-- ── BibTeX parser ─────────────────────────────────────────────────────────────
-- Extracts `file` (PDF path) and `url` fields from a .bib file.

local function extract_first_path(file_val)
  -- Handles semicolon-separated file lists; takes the first segment.
  -- Segment formats: :path:type | desc:path:type | plain/path
  for segment in (file_val .. ";"):gmatch("([^;]+);") do
    segment = segment:match("^%s*(.-)%s*$")
    if segment ~= "" then
      local parts = {}
      for p in (segment .. ":"):gmatch("([^:]*):") do
        table.insert(parts, p)
      end
      local path
      if     #parts >= 3 then path = parts[2]
      elseif #parts == 2 then
        path = parts[1]:match("[/\\%.%a]") and parts[1] or nil
      elseif #parts == 1 then path = parts[1]
      end
      path = path and path:match("^%s*(.-)%s*$") or nil
      if path and path ~= "" then return path end
    end
  end
end

local function parse_bib_entries(bib_path)
  local result = {}
  local f = io.open(bib_path, "r")
  if not f then
    io.stderr:write("[full-citation] Warning: cannot open bibliography: "
                    .. bib_path .. "\n")
    return result
  end
  local current_key = nil
  local acc_file    = nil  -- accumulates multi-line `file` values
  for line in f:lines() do
    local k = line:match("^@%a+%s*{%s*([^,%s]+)")
    if k then
      current_key = k
      acc_file    = nil
      if not result[current_key] then result[current_key] = {} end
    end
    if current_key then
      local entry = result[current_key]
      -- url field (single-line)
      if not entry.url then
        local url = line:match("[Uu]rl%s*=%s*{([^}]+)}")
                 or line:match('[Uu]rl%s*=%s*"([^"]+)"')
        if url then entry.url = url:match("^%s*(.-)%s*$") end
      end
      -- file field (handle multi-line)
      if not entry.path then
        if not acc_file then
          local val = line:match("[Ff]ile%s*=%s*{([^}]*)}")
          if val then
            local p = extract_first_path(val)
            if p then entry.path = p end
          else
            local partial = line:match("[Ff]ile%s*=%s*{(.*)")
            if partial then acc_file = partial end
          end
        else
          if line:match("}") then
            acc_file = acc_file .. " " .. (line:match("^(.-)}") or "")
            local p  = extract_first_path(acc_file)
            if p then entry.path = p end
            acc_file = nil
          else
            acc_file = acc_file .. " " .. line
          end
        end
      end
    end
  end
  f:close()
  local bib_dir  = (bib_path:match("^(.+)[/\\][^/\\]+$") or ".")
  local bib_name = (bib_path:match("([^/\\]+)$") or bib_path):gsub("%.[^.]+$", "")
  for _, entry in pairs(result) do
    entry.bib_dir  = bib_dir
    entry.bib_name = bib_name
  end
  return result
end


-- ── File utilities ────────────────────────────────────────────────────────────

local function basename(p) return p:match("([^/\\]+)$") or p end
local function dirname(p)  return p:match("^(.+)[/\\][^/\\]+$") or "." end

local function file_exists(p)
  local f = io.open(p, "rb"); if f then f:close() end; return f ~= nil
end

local function copy_file(src, dest)
  local f = io.open(src, "rb"); if not f then return false end
  local data = f:read("*all"); f:close()
  local g = io.open(dest, "wb"); if not g then return false end
  g:write(data); g:close(); return true
end

local function ensure_dir(path)
  -- POSIX mkdir -p; works on macOS and Linux.
  os.execute(string.format("mkdir -p '%s'", path:gsub("'", "'\\''")))
end


-- ── Citation key extraction (post-citeproc AST) ───────────────────────────────
-- After citeproc, [@key] → Span {data-cites="key"}. Before citeproc: Cite node.

local function find_key_in_inlines(inlines)
  for _, el in ipairs(inlines) do
    if el.t == "Span" then
      local dc = el.attributes and el.attributes["data-cites"]
      if dc then return dc:match("(%S+)") end
      if el.content then
        local k = find_key_in_inlines(el.content)
        if k then return k end
      end
    elseif el.t == "Cite" then
      if el.citations and el.citations[1] then return el.citations[1].id end
    end
  end
end

local function find_key_in_div(div)
  local ref = div.attributes and div.attributes["ref"]
  if ref then return ref:gsub("^@", "") end
  for _, block in ipairs(div.content) do
    if block.t == "Para" or block.t == "Plain" then
      local k = find_key_in_inlines(block.content)
      if k then return k end
    end
  end
end


-- ── Refs collection ───────────────────────────────────────────────────────────

local function collect_refs(blocks)
  for _, block in ipairs(blocks) do
    if block.t == "Div" and block.identifier == "refs" then
      for _, child in ipairs(block.content) do
        if child.t == "Div" then
          local k = child.identifier:match("^ref%-(.+)$")
          if k then refs[k] = child.content end
        end
      end
      return
    end
  end
end


-- ── Block/inline manipulation ─────────────────────────────────────────────────

-- Return a new list of blocks with `link_inlines` appended inline to the last
-- Para or Plain block. Does NOT modify the input blocks (no shared-ref bugs).
local function with_appended_links(formatted_blocks, link_inlines)
  if #link_inlines == 0 then
    local r = {}
    for _, b in ipairs(formatted_blocks) do table.insert(r, b) end
    return r
  end
  local result        = {}
  local last_para_idx = nil
  for i, b in ipairs(formatted_blocks) do
    table.insert(result, b)
    if b.t == "Para" or b.t == "Plain" then last_para_idx = i end
  end
  if last_para_idx then
    local orig        = result[last_para_idx]
    local new_content = pandoc.List{}
    for _, el in ipairs(orig.content)  do new_content:insert(el) end
    for _, el in ipairs(link_inlines)  do new_content:insert(el) end
    result[last_para_idx] = pandoc.Para(new_content)
  else
    table.insert(result, pandoc.Para(pandoc.List(link_inlines)))
  end
  return result
end

-- Extract the inlines from the first Para/Plain in a block list.
local function first_para_inlines(blocks)
  for _, b in ipairs(blocks) do
    if b.t == "Para" or b.t == "Plain" then
      local r = pandoc.List{}
      for _, el in ipairs(b.content) do r:insert(el) end
      return r
    end
  end
  return pandoc.List{}
end


-- ── Main filter ───────────────────────────────────────────────────────────────

function Pandoc(doc)
  local meta = doc.meta

  -- Read boolean front-matter option.
  -- Pandoc 3.x returns raw Lua booleans for MetaBool values, so we must
  -- use `== nil` (not `not v`) to detect "not set" vs. explicitly false.
  local function bool_opt(name, default)
    local v = meta[name]
    if v == nil then return default end
    if type(v) == "boolean" then return v end
    local s = pandoc.utils.stringify(v)
    return s ~= "false" and s ~= "0"
  end

  local suppress_bib   = bool_opt("full-citation-suppress-bibliography", false)
  local attach_enabled = bool_opt("full-citation-attachments", true)
  local full_all       = bool_opt("full-citation-all", false)

  -- 1. Parse bib files for attachment paths and URLs. ------------------------
  local bib_meta = meta.bibliography
  if bib_meta then
    local bib_list = bib_meta.t == "MetaList"
        and pandoc.List.map(bib_meta, pandoc.utils.stringify)
        or  { pandoc.utils.stringify(bib_meta) }
    for _, bib_path in ipairs(bib_list) do
      for key, entry in pairs(parse_bib_entries(bib_path)) do
        bib_entries[key] = entry
      end
    end
  end

  -- 2. Run citeproc to build the refs map from the #refs div. -----------------
  --    pandoc.utils.citeproc() populates the #refs div but does NOT convert
  --    inline Cite elements to Spans. We therefore keep bibliography/nocite
  --    metadata intact so pandoc's own subsequent citeproc pass handles any
  --    remaining inline citations normally.
  --    We strip our internally-generated #refs div from the blocks (step 5);
  --    pandoc's citeproc will regenerate it (unless suppressed).
  local processed = pandoc.utils.citeproc(doc)
  collect_refs(processed.blocks)

  -- 3. Output context. -------------------------------------------------------
  local out_file = PANDOC_STATE.output_file
  local out_dir  = out_file and dirname(out_file) or "."
  local is_html  = FORMAT:match("html")

  -- 4. Build [PDF] / [online] inline link elements for a given key. ----------
  --    Copies the PDF to {bib-name}-attachments/ on first call per key.
  local copied = {}  -- track already-copied files to avoid redundant copies
  local function make_link_inlines(key)
    local entry  = bib_entries[key] or {}
    local links  = pandoc.List{}

    -- [PDF] – HTML output only, when attachments are enabled
    if is_html and attach_enabled and entry.path then
      local src = entry.path
      if not file_exists(src) then
        src = (entry.bib_dir or ".") .. "/" .. entry.path
      end
      if file_exists(src) then
        local attach_dir_name = (entry.bib_name or "bib") .. "-attachments"
        local attach_dir      = out_dir .. "/" .. attach_dir_name
        local name            = basename(src)
        local dest            = attach_dir .. "/" .. name
        local href            = attach_dir_name .. "/" .. name
        if not copied[dest] then
          ensure_dir(attach_dir)
          if copy_file(src, dest) then
            copied[dest] = true
          else
            io.stderr:write("[full-citation] Warning: failed to copy: "
                            .. src .. "\n")
            dest = nil
          end
        end
        if copied[dest] then
          links:insert(pandoc.Space())
          links:insert(pandoc.Link({pandoc.Str("[PDF]")}, href, href))
        end
      else
        io.stderr:write("[full-citation] Warning: PDF not found: "
                        .. entry.path .. "\n")
      end
    end

    -- [online] – all output formats, when url field exists
    if entry.url then
      links:insert(pandoc.Space())
      links:insert(pandoc.Link({pandoc.Str("[online]")}, entry.url, entry.url))
    end

    return links
  end

  -- 5. Replace .full-citation divs. ------------------------------------------
  --    Also strip our internally-generated #refs div; pandoc's own citeproc
  --    For non-HTML: use suppress-bibliography so citeproc omits it entirely.
  --    For HTML: let citeproc generate #refs (Quarto needs it for citation hover
  --    tooltips); we'll add a CSS rule after the block loop to hide it visually.
  if suppress_bib and not is_html then
    processed.meta["suppress-bibliography"] = true
  end

  local new_blocks = {}
  for _, block in ipairs(processed.blocks) do

    if block.t == "Div" and block.identifier == "refs" then
      -- Always drop our internal #refs div (pandoc's citeproc will regenerate).

    elseif block.t == "Div" and block.classes:includes("full-citation") then
      local key       = find_key_in_div(block)
      local formatted = key and refs[key]
      if formatted then
        local out = with_appended_links(formatted, make_link_inlines(key))
        for _, b in ipairs(out) do table.insert(new_blocks, b) end
      else
        if key then
          io.stderr:write("[full-citation] Warning: no formatted ref for: "
                          .. key .. "\n")
        else
          io.stderr:write("[full-citation] Warning: cannot determine citation "
                          .. "key in .full-citation div\n")
        end
        table.insert(new_blocks, block)
      end

    else
      table.insert(new_blocks, block)
    end
  end
  -- For HTML bibliography suppression: inject a CSS rule that hides Quarto's
  -- bibliography appendix section but keeps #ref-KEY divs in the DOM so that
  -- citation hover tooltips (which use document.getElementById) still work.
  if suppress_bib and is_html then
    table.insert(new_blocks, pandoc.RawBlock("html",
      "<style>#quarto-bibliography{display:none!important}</style>"))
  end

  processed.blocks = pandoc.Blocks(new_blocks)

  -- 6. When full-citation-all: expand every remaining citation. ---------------
  --    pandoc.utils.citeproc() populates the #refs div but does NOT convert
  --    inline Cite elements to Spans in this context. Handle both node types:
  --      • Cite  – unconverted inline citations (primary case in Quarto filters)
  --      • Span  – data-cites attribute, for completeness / future-proofing
  if full_all then
    local function expand_key(key)
      local formatted = key and refs[key]
      if not formatted then return end
      local inlines = first_para_inlines(formatted)
      local links   = make_link_inlines(key)
      for _, el in ipairs(links) do inlines:insert(el) end
      return inlines
    end

    local walked = {}
    for _, block in ipairs(processed.blocks) do
      table.insert(walked, pandoc.walk_block(block, {
        Cite = function(cite)
          if cite.citations and cite.citations[1] then
            return expand_key(cite.citations[1].id)
          end
        end,
        Span = function(span)
          local dc = span.attributes and span.attributes["data-cites"]
          if dc then return expand_key(dc:match("(%S+)")) end
        end,
      }))
    end
    processed.blocks = pandoc.Blocks(walked)
  end

  return processed
end
