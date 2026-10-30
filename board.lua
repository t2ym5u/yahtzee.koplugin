-- ---------------------------------------------------------------------------
-- YahtzeeBoard — Yahtzee (Yam's) game logic, 1-4 players
--
-- Pure logic, no UI: five dice, up to three rolls a turn, a 13-box score
-- sheet per player. Implements the official Hasbro scoring:
--   * upper section (ones..sixes) earns a 35-point bonus at 63 or more;
--   * every Yahtzee after the first earns 100 points when the Yahtzee box
--     already holds 50, and is then placed by the forced Joker rule (the
--     matching upper box if open, else any lower box at full value -- full
--     house 25, straights 30/40 -- else any upper box for zero).
--
-- Dice are 0 until the turn's first roll. Randomness comes from `rng`
-- (math.random by default), so tests and simulations can drive it.
-- ---------------------------------------------------------------------------

local YahtzeeBoard = {}
YahtzeeBoard.__index = YahtzeeBoard

local NUM_DICE       = 5
local MAX_ROLLS      = 3
local UPPER_BONUS_AT = 63
local UPPER_BONUS    = 35
local YAHTZEE_SCORE  = 50
local YAHTZEE_BONUS  = 100
local MAX_PLAYERS    = 4

local CATEGORIES = {
    "ones", "twos", "threes", "fours", "fives", "sixes",
    "three_kind", "four_kind", "full_house",
    "small_straight", "large_straight", "yahtzee", "chance",
}
local NUM_ROUNDS = #CATEGORIES

-- Face counted by each upper box.
local UPPER_FACE = { ones = 1, twos = 2, threes = 3, fours = 4, fives = 5, sixes = 6 }

local function counts_of(dice)
    local c = { 0, 0, 0, 0, 0, 0 }
    for i = 1, #dice do
        local f = dice[i]
        if f >= 1 and f <= 6 then c[f] = c[f] + 1 end
    end
    return c
end

local function is_yahtzee(dice)
    local f = dice[1]
    if not f or f < 1 then return false end
    for i = 2, NUM_DICE do
        if dice[i] ~= f then return false end
    end
    return true
end

-- Longest run of consecutive faces present in counts c.
local function longest_run(c)
    local best, run = 0, 0
    for f = 1, 6 do
        if c[f] > 0 then
            run = run + 1
            if run > best then best = run end
        else
            run = 0
        end
    end
    return best
end

-- Score `dice` would earn in `cat` under the plain rules (no Joker).
local function raw_score(cat, dice)
    local c = counts_of(dice)
    local sum = 0
    for f = 1, 6 do sum = sum + f * c[f] end
    local face = UPPER_FACE[cat]
    if face then return face * c[face] end
    local maxc, has3, has2 = 0, false, false
    for f = 1, 6 do
        if c[f] > maxc then maxc = c[f] end
        if c[f] == 3 then has3 = true end
        if c[f] == 2 then has2 = true end
    end
    if cat == "three_kind" then return maxc >= 3 and sum or 0
    elseif cat == "four_kind" then return maxc >= 4 and sum or 0
    elseif cat == "full_house" then return (has3 and has2) and 25 or 0
    elseif cat == "small_straight" then return longest_run(c) >= 4 and 30 or 0
    elseif cat == "large_straight" then return longest_run(c) >= 5 and 40 or 0
    elseif cat == "yahtzee" then return maxc == 5 and YAHTZEE_SCORE or 0
    elseif cat == "chance" then return sum
    end
    return 0
end

-- ---------------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------------

-- opts.players: list of { ai = bool } (1..4 entries, default one human).
-- opts.rng:     function(n) -> 1..n (default math.random).
function YahtzeeBoard:new(opts)
    opts = opts or {}
    local o = setmetatable({}, self)
    o.rng = opts.rng or math.random
    o:newGame(opts.players)
    return o
end

function YahtzeeBoard:newGame(players)
    players = players or { { ai = false } }
    self.players = {}
    for i = 1, math.min(#players, MAX_PLAYERS) do
        self.players[i] = { ai = players[i].ai and true or false,
                            scores = {}, yahtzee_bonus = 0 }
    end
    if #self.players == 0 then
        self.players[1] = { ai = false, scores = {}, yahtzee_bonus = 0 }
    end
    self.current   = 1
    self.round     = 1
    self.game_over = false
    self:_startTurn()
end

function YahtzeeBoard:_startTurn()
    self.dice       = { 0, 0, 0, 0, 0 }
    self.held       = { false, false, false, false, false }
    self.rolls_left = MAX_ROLLS
end

-- ---------------------------------------------------------------------------
-- Turn actions
-- ---------------------------------------------------------------------------

function YahtzeeBoard:hasRolled()
    return self.rolls_left < MAX_ROLLS
end

-- Roll every die not held. Returns false when no roll is left.
function YahtzeeBoard:roll()
    if self.game_over or self.rolls_left <= 0 then return false end
    local first = not self:hasRolled()
    for i = 1, NUM_DICE do
        if first or not self.held[i] then
            self.dice[i] = self.rng(6)
        end
        if first then self.held[i] = false end
    end
    self.rolls_left = self.rolls_left - 1
    return true
end

-- Holding is only meaningful between rolls: after the first, before the last.
function YahtzeeBoard:canHold()
    return not self.game_over and self:hasRolled() and self.rolls_left > 0
end

function YahtzeeBoard:toggleHold(i)
    if not self:canHold() or not self.dice[i] then return false end
    self.held[i] = not self.held[i]
    return true
end

function YahtzeeBoard:setHolds(held)
    if not self:canHold() then return false end
    for i = 1, NUM_DICE do self.held[i] = held[i] and true or false end
    return true
end

-- ---------------------------------------------------------------------------
-- Scoring
-- ---------------------------------------------------------------------------

function YahtzeeBoard:currentPlayer()
    return self.players[self.current]
end

-- Categories `p` may score `dice` in, honouring the forced Joker rule.
-- Returns a set { cat = true }.
function YahtzeeBoard:legalCategories(p, dice)
    p    = p or self:currentPlayer()
    dice = dice or self.dice
    local open = {}
    for _, cat in ipairs(CATEGORIES) do
        if p.scores[cat] == nil then open[cat] = true end
    end
    if not (is_yahtzee(dice) and p.scores.yahtzee ~= nil) then
        return open
    end
    -- Joker: the matching upper box first, then any lower box, then any
    -- upper box.
    local upper = CATEGORIES[dice[1]]
    if open[upper] then return { [upper] = true } end
    local lower = {}
    for i = 7, NUM_ROUNDS do
        if open[CATEGORIES[i]] then lower[CATEGORIES[i]] = true end
    end
    if next(lower) then return lower end
    return open
end

-- Points `dice` would put in `cat` for `p` (box only, not the Yahtzee bonus),
-- or nil when that box is not a legal choice.
function YahtzeeBoard:scoreFor(cat, p, dice)
    p    = p or self:currentPlayer()
    dice = dice or self.dice
    if not self:legalCategories(p, dice)[cat] then return nil end
    if is_yahtzee(dice) and p.scores.yahtzee ~= nil and not UPPER_FACE[cat] then
        if cat == "full_house" then return 25 end
        if cat == "small_straight" then return 30 end
        if cat == "large_straight" then return 40 end
    end
    return raw_score(cat, dice)
end

-- Yahtzee bonus `dice` would earn `p` right now (100 or 0).
function YahtzeeBoard:bonusFor(p, dice)
    p    = p or self:currentPlayer()
    dice = dice or self.dice
    if is_yahtzee(dice) and p.scores.yahtzee == YAHTZEE_SCORE then
        return YAHTZEE_BONUS
    end
    return 0
end

-- Score the current dice in `cat` and pass the turn. Returns the points
-- written (box + Yahtzee bonus), or nil if the move is illegal.
function YahtzeeBoard:score(cat)
    if self.game_over or not self:hasRolled() then return nil end
    local p = self:currentPlayer()
    local pts = self:scoreFor(cat, p)
    if not pts then return nil end
    local bonus = self:bonusFor(p)
    p.yahtzee_bonus = p.yahtzee_bonus + bonus
    p.scores[cat] = pts
    self:_nextTurn()
    return pts + bonus
end

function YahtzeeBoard:_nextTurn()
    self.current = self.current + 1
    if self.current > #self.players then
        self.current = 1
        self.round = self.round + 1
    end
    if self.round > NUM_ROUNDS then
        self.round     = NUM_ROUNDS
        self.game_over = true
        self.current   = 1
    end
    self:_startTurn()
end

-- ---------------------------------------------------------------------------
-- Totals
-- ---------------------------------------------------------------------------

function YahtzeeBoard.upperSum(p)
    local s = 0
    for i = 1, 6 do s = s + (p.scores[CATEGORIES[i]] or 0) end
    return s
end

function YahtzeeBoard.upperBonus(p)
    return YahtzeeBoard.upperSum(p) >= UPPER_BONUS_AT and UPPER_BONUS or 0
end

function YahtzeeBoard.lowerSum(p)
    local s = 0
    for i = 7, NUM_ROUNDS do s = s + (p.scores[CATEGORIES[i]] or 0) end
    return s
end

function YahtzeeBoard.total(p)
    return YahtzeeBoard.upperSum(p) + YahtzeeBoard.upperBonus(p)
         + YahtzeeBoard.lowerSum(p) + (p.yahtzee_bonus or 0)
end

-- Indices of the players holding the best total (several on a tie).
function YahtzeeBoard:leaders()
    local best, out = -1, {}
    for i, p in ipairs(self.players) do
        local t = YahtzeeBoard.total(p)
        if t > best then best, out = t, { i }
        elseif t == best then out[#out + 1] = i end
    end
    return out, best
end

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

function YahtzeeBoard:serialize()
    local players = {}
    for i, p in ipairs(self.players) do
        local scores = {}
        for k, v in pairs(p.scores) do scores[k] = v end
        players[i] = { ai = p.ai, scores = scores, yahtzee_bonus = p.yahtzee_bonus }
    end
    return {
        players    = players,
        current    = self.current,
        round      = self.round,
        game_over  = self.game_over,
        dice       = { self.dice[1], self.dice[2], self.dice[3], self.dice[4], self.dice[5] },
        held       = { self.held[1], self.held[2], self.held[3], self.held[4], self.held[5] },
        rolls_left = self.rolls_left,
    }
end

function YahtzeeBoard:load(data)
    if type(data) ~= "table" or type(data.players) ~= "table"
            or #data.players == 0 or type(data.dice) ~= "table" then
        return false
    end
    self.players = {}
    for i, p in ipairs(data.players) do
        local scores = {}
        for k, v in pairs(p.scores or {}) do
            if UPPER_FACE[k] or k == "three_kind" or k == "four_kind"
                    or k == "full_house" or k == "small_straight"
                    or k == "large_straight" or k == "yahtzee" or k == "chance" then
                scores[k] = tonumber(v)
            end
        end
        self.players[i] = { ai = p.ai and true or false, scores = scores,
                            yahtzee_bonus = tonumber(p.yahtzee_bonus) or 0 }
    end
    self.current    = math.max(1, math.min(#self.players, tonumber(data.current) or 1))
    self.round      = tonumber(data.round) or 1
    self.game_over  = data.game_over and true or false
    self.rolls_left = tonumber(data.rolls_left) or MAX_ROLLS
    self.dice, self.held = {}, {}
    for i = 1, NUM_DICE do
        self.dice[i] = tonumber(data.dice[i]) or 0
        self.held[i] = (data.held and data.held[i]) and true or false
    end
    return true
end

YahtzeeBoard.CATEGORIES     = CATEGORIES
YahtzeeBoard.UPPER_FACE     = UPPER_FACE
YahtzeeBoard.NUM_DICE       = NUM_DICE
YahtzeeBoard.MAX_ROLLS      = MAX_ROLLS
YahtzeeBoard.NUM_ROUNDS     = NUM_ROUNDS
YahtzeeBoard.MAX_PLAYERS    = MAX_PLAYERS
YahtzeeBoard.UPPER_BONUS_AT = UPPER_BONUS_AT
YahtzeeBoard.UPPER_BONUS    = UPPER_BONUS
YahtzeeBoard.YAHTZEE_BONUS  = YAHTZEE_BONUS
YahtzeeBoard.rawScore       = raw_score
YahtzeeBoard.isYahtzee      = is_yahtzee
YahtzeeBoard.countsOf       = counts_of

return YahtzeeBoard
