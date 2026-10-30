local Blitbuffer     = require("ffi/blitbuffer")
local Font           = require("ui/font")
local GestureRange   = require("ui/gesturerange")
local Geom           = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local RenderText     = require("ui/rendertext")
local Screen         = require("device").screen
local UIManager      = require("ui/uimanager")
local _              = require("i18n")

local C_BG      = Blitbuffer.COLOR_WHITE
local C_INK     = Blitbuffer.COLOR_BLACK
local C_PREVIEW = Blitbuffer.COLOR_GRAY_7   -- what the dice would score, not yet written
local C_RULE    = Blitbuffer.COLOR_GRAY_9   -- thin row rules on the sheet
local C_SHADE   = Blitbuffer.COLOR_GRAY_E   -- totals rows

-- Standard pip layout (fractions of the die's side) for faces 1-6.
local PIP_LAYOUT = {
    [1] = { {0.5, 0.5} },
    [2] = { {0.27, 0.27}, {0.73, 0.73} },
    [3] = { {0.27, 0.27}, {0.5, 0.5}, {0.73, 0.73} },
    [4] = { {0.27, 0.27}, {0.73, 0.27}, {0.27, 0.73}, {0.73, 0.73} },
    [5] = { {0.27, 0.27}, {0.73, 0.27}, {0.5, 0.5}, {0.27, 0.73}, {0.73, 0.73} },
    [6] = { {0.27, 0.25}, {0.73, 0.25}, {0.27, 0.5}, {0.73, 0.5}, {0.27, 0.75}, {0.73, 0.75} },
}

-- Font:getFace() scales its size argument by DPI; this takes a pixel size.
local DPI_SCALE = Screen:scaleBySize(1000) / 1000
local function face_px(name, px)
    return Font:getFace(name, math.max(6, math.floor(px / DPI_SCALE)))
end

local function text_width(face, text)
    return RenderText:sizeUtf8Text(0, 9999, face, text, true, false).x
end

-- Largest face (at most max_px) whose rendering of every text fits in width.
local function fit_face(name, max_px, width, texts)
    local px = math.floor(max_px)
    while px > 8 do
        local face = face_px(name, px)
        local ok = true
        for _, t in ipairs(texts) do
            if text_width(face, t) > width then ok = false; break end
        end
        if ok then return face end
        px = px - 1
    end
    return face_px(name, 8)
end

local function draw_text(bb, face, text, x, cy, color)
    local m = RenderText:sizeUtf8Text(0, 9999, face, text, true, false)
    local ty = cy + math.floor((m.y_top - m.y_bottom) / 2)
    RenderText:renderUtf8Text(bb, x, ty, face, text, true, false, color)
    return m.x
end

local function draw_centered(bb, face, text, cx, cy, color)
    local w = text_width(face, text)
    draw_text(bb, face, text, cx - math.floor(w / 2), cy, color)
end

-- ---------------------------------------------------------------------------
-- YahtzeeBoardWidget — the five dice over the score sheet
--
-- Tapping a die holds/releases it; tapping a box row scores there (the
-- screen asks for a second tap to confirm). Held dice are drawn inverted,
-- white pips on black: the one state that must read at a glance.
-- ---------------------------------------------------------------------------

local YahtzeeBoardWidget = InputContainer:extend{
    board        = nil,
    names        = nil,   -- short column header per player
    labels       = nil,   -- { cat = label } for the sheet's left column
    pending      = nil,   -- category awaiting the confirming tap
    max_width    = 400,
    max_height   = 600,
    onDieTap     = nil,
    onCategoryTap = nil,
}

-- Sheet rows, top to bottom. "cat" rows are tappable boxes.
local function sheet_rows(board)
    local rows = { { kind = "header" } }
    for i = 1, 6 do rows[#rows + 1] = { kind = "cat", cat = board.CATEGORIES[i] } end
    rows[#rows + 1] = { kind = "upper_bonus" }
    for i = 7, board.NUM_ROUNDS do rows[#rows + 1] = { kind = "cat", cat = board.CATEGORIES[i] } end
    rows[#rows + 1] = { kind = "yahtzee_bonus" }
    rows[#rows + 1] = { kind = "total" }
    return rows
end

function YahtzeeBoardWidget:init()
    local w, h  = self.max_width, self.max_height
    local board = self.board
    local nd    = board.NUM_DICE
    self.rows   = sheet_rows(board)
    local nrows = #self.rows

    local gap      = math.max(4, math.floor(w / 50))
    -- Dice take up to a fifth of the height; the sheet gets the rest, with
    -- rows capped so a tall screen doesn't stretch them absurdly.
    local die      = math.min(math.floor((w - (nd + 1) * gap) / nd), math.floor(h * 0.2))
    local row_h    = math.floor((h - die - 3 * gap) / nrows)
    row_h          = math.max(16, math.min(row_h, math.floor(die * 0.55)))
    self.gap, self.die, self.row_h = gap, die, row_h

    local np     = #board.players
    local col_w  = math.floor(w * (np == 1 and 0.24 or (np == 2 and 0.2 or 0.16)))
    self.col_w   = col_w
    self.label_w = w - np * col_w

    self.w = w
    self.h = die + 3 * gap + nrows * row_h
    self.dimen      = Geom:new{ x = 0, y = 0, w = self.w, h = self.h }
    self.paint_rect = Geom:new{ x = 0, y = 0, w = self.w, h = self.h }

    local pad = math.floor(row_h * 0.25)
    self.pad = pad
    local label_texts = {}
    for _, row in ipairs(self.rows) do
        label_texts[#label_texts + 1] = self:_rowLabel(row)
    end
    self.label_face = fit_face("cfont", row_h * 0.55, self.label_w - 2 * pad, label_texts)
    local cell_texts = { "888", "88/63" }
    for _, n in ipairs(self.names or {}) do cell_texts[#cell_texts + 1] = n end
    self.cell_face  = fit_face("cfont", row_h * 0.6, col_w - 2 * pad, cell_texts)
    self.bold_face  = fit_face("tfont", row_h * 0.6, col_w - 2 * pad, cell_texts)
    self.label_bold = fit_face("tfont", row_h * 0.55, self.label_w - 2 * pad, label_texts)
    -- Previews (what the dice would score) are lighter and a size smaller
    -- than written scores, so the two never read alike.
    self.preview_face = fit_face("cfont", row_h * 0.48, col_w - 2 * pad, cell_texts)

    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = function() return self.paint_rect end } },
    }
end

function YahtzeeBoardWidget:_rowLabel(row)
    if row.kind == "cat" then return self.labels[row.cat] or row.cat end
    if row.kind == "upper_bonus" then return _("Bonus (63+)") end
    if row.kind == "yahtzee_bonus" then return _("Yahtzee bonus") end
    if row.kind == "total" then return _("Total") end
    return ""
end

function YahtzeeBoardWidget:refresh()
    local rect = self.paint_rect
    UIManager:setDirty(self, function()
        return "ui", Geom:new{ x = rect.x, y = rect.y, w = rect.w, h = rect.h }
    end)
end

-- Local x of die i's left edge (dice are spread evenly across the width).
function YahtzeeBoardWidget:_dieX(i)
    local nd = self.board.NUM_DICE
    local spare = self.w - nd * self.die
    local g = math.floor(spare / (nd + 1))
    return g + (i - 1) * (self.die + g)
end

function YahtzeeBoardWidget:_sheetY()
    return self.die + 2 * self.gap
end

function YahtzeeBoardWidget:onTap(_, ges)
    if not (ges and ges.pos) then return false end
    local lx = ges.pos.x - self.paint_rect.x
    local ly = ges.pos.y - self.paint_rect.y
    if lx < 0 or ly < 0 or lx >= self.w or ly >= self.h then return false end
    -- Dice: the whole band, split into equal columns, so a near miss between
    -- two dice still lands on one.
    if ly < self.die + 2 * self.gap then
        local nd = self.board.NUM_DICE
        local i = math.min(nd, math.floor(lx / (self.w / nd)) + 1)
        if self.onDieTap then self.onDieTap(i) end
        return true
    end
    local r = math.floor((ly - self:_sheetY()) / self.row_h) + 1
    local row = self.rows[r]
    if row and row.kind == "cat" and self.onCategoryTap then
        self.onCategoryTap(row.cat)
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Painting
-- ---------------------------------------------------------------------------

function YahtzeeBoardWidget:_paintDie(bb, dx, dy, s, value, held)
    local radius = math.max(2, math.floor(s * 0.14))
    local border = math.max(2, math.floor(s * 0.04))
    local fill, pip = C_BG, C_INK
    if held then fill, pip = C_INK, C_BG end
    bb:paintRoundedRect(dx, dy, s, s, fill, radius)
    bb:paintBorder(dx, dy, s, s, border, C_INK, radius)
    local layout = PIP_LAYOUT[value]
    if not layout then return end   -- not rolled yet: a blank die
    local pr = math.max(3, math.floor(s * 0.085))
    for _, p in ipairs(layout) do
        bb:paintCircle(dx + math.floor(s * p[1]), dy + math.floor(s * p[2]), pr, pip)
    end
end

function YahtzeeBoardWidget:paintTo(bb, x, y)
    self.paint_rect = Geom:new{ x = x, y = y, w = self.w, h = self.h }
    local board = self.board
    bb:paintRect(x, y, self.w, self.h, C_BG)

    for i = 1, board.NUM_DICE do
        self:_paintDie(bb, x + self:_dieX(i), y + self.gap, self.die,
                       board.dice[i], board.held[i])
    end

    local Board   = getmetatable(board)
    local sy      = y + self:_sheetY()
    local row_h   = self.row_h
    local np      = #board.players
    local label_w = self.label_w
    local col_w   = self.col_w
    local pad     = self.pad
    local cur     = board.current
    local live    = not board.game_over
    local legal   = (live and board:hasRolled()) and board:legalCategories() or {}
    local rule    = math.max(1, math.floor(row_h / 25))
    local thick   = math.max(2, rule * 3)

    for r, row in ipairs(self.rows) do
        local ry = sy + (r - 1) * row_h
        local cy = ry + math.floor(row_h / 2)
        local is_sum = row.kind ~= "cat" and row.kind ~= "header"
        if is_sum then bb:paintRect(x, ry, self.w, row_h, C_SHADE) end
        local lface = (row.kind == "total") and self.label_bold or self.label_face
        draw_text(bb, lface, self:_rowLabel(row), x + pad, cy, C_INK)

        for i = 1, np do
            local p  = board.players[i]
            local cx = x + label_w + (i - 1) * col_w
            local ccx = cx + math.floor(col_w / 2)
            if row.kind == "header" then
                local name = (self.names and self.names[i]) or tostring(i)
                if live and i == cur then
                    bb:paintRect(cx, ry, col_w, row_h, C_INK)
                    draw_centered(bb, self.bold_face, name, ccx, cy, C_BG)
                else
                    draw_centered(bb, self.bold_face, name, ccx, cy, C_INK)
                end
            elseif row.kind == "cat" then
                local v = p.scores[row.cat]
                if v ~= nil then
                    draw_centered(bb, self.cell_face, tostring(v), ccx, cy, C_INK)
                elseif live and i == cur and legal[row.cat] then
                    local pts = board:scoreFor(row.cat) + board:bonusFor()
                    if self.pending == row.cat then
                        bb:paintRect(cx + rule, ry + rule, col_w - 2 * rule, row_h - 2 * rule, C_INK)
                        draw_centered(bb, self.bold_face, tostring(pts), ccx, cy, C_BG)
                    else
                        draw_centered(bb, self.preview_face, tostring(pts), ccx, cy, C_PREVIEW)
                    end
                end
            elseif row.kind == "upper_bonus" then
                local txt
                if Board.upperBonus(p) > 0 then
                    txt = tostring(Board.UPPER_BONUS)
                else
                    txt = Board.upperSum(p) .. "/" .. Board.UPPER_BONUS_AT
                end
                draw_centered(bb, self.cell_face, txt, ccx, cy, C_INK)
            elseif row.kind == "yahtzee_bonus" then
                local yb = p.yahtzee_bonus or 0
                draw_centered(bb, self.cell_face, yb > 0 and tostring(yb) or "–", ccx, cy, C_INK)
            elseif row.kind == "total" then
                draw_centered(bb, self.bold_face, tostring(Board.total(p)), ccx, cy, C_INK)
            end
        end

        -- Rule under the row: heavy under the header, before the lower
        -- section and before the total, light elsewhere.
        local next_row = self.rows[r + 1]
        local heavy = row.kind == "header" or row.kind == "upper_bonus"
                      or (next_row and next_row.kind == "total") or not next_row
        local t = heavy and thick or rule
        bb:paintRect(x, ry + row_h - t, self.w, t, heavy and C_INK or C_RULE)
    end

    -- Column rules, and the sheet's top edge.
    local sheet_h = #self.rows * row_h
    bb:paintRect(x, sy, self.w, thick, C_INK)
    for i = 0, np do
        local cx = x + label_w + i * col_w
        if i == np then cx = x + self.w - thick end
        bb:paintRect(cx, sy, (i == 0 or i == np) and thick or rule, sheet_h, C_INK)
    end
    bb:paintRect(x, sy, thick, sheet_h, C_INK)
end

return YahtzeeBoardWidget
