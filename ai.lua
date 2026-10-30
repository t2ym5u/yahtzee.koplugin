-- ---------------------------------------------------------------------------
-- YahtzeeAI — expected-value keeper for the computer players
--
-- Within a turn the AI plays optimally for a fixed end-of-turn value: every
-- hand of five dice gets a value (best box to score it in, see hand_value),
-- and the dice to keep are chosen by exact expectation over the remaining
-- rolls. Only 252 distinct hands and 462 distinct "keeps" (sub-multisets of
-- 0..5 dice) exist, so the full two-roll lookahead is a few thousand
-- multiply-adds -- well under a millisecond, even on an e-reader.
--
-- Across turns it is greedy: the end-of-turn value is "points now minus what
-- this box is usually worth", which stops it from burning its Yahtzee or
-- straight boxes on a poor hand. The upper-section bonus is chased by
-- rewarding every pip above three-of-a-face (the par that reaches 63).
-- ---------------------------------------------------------------------------

local AI = {}

-- Typical points each box ends up with in good play: the opportunity cost
-- of filling it now. Tuned by simulation (see the README for the average).
local BOX_WORTH = {
    ones = 2.0, twos = 5.0, threes = 8.5, fours = 12.0, fives = 15.5, sixes = 19.0,
    three_kind = 20.0, four_kind = 12.0, full_house = 22.0,
    small_straight = 28.0, large_straight = 30.0, yahtzee = 18.0, chance = 22.0,
}
local PARAMS = {
    par_weight  = 1.0,   -- value of one pip above/below par in the upper box
    bonus_reach = 10,    -- extra for the score that secures the 35 bonus
}

-- ---------------------------------------------------------------------------
-- Multiset tables (built once per session)
-- ---------------------------------------------------------------------------

-- A multiset of dice is a count vector c[1..6]; its key is c in base 6.
local function key_of(c)
    return c[1] + 6 * c[2] + 36 * c[3] + 216 * c[4] + 1296 * c[5] + 7776 * c[6]
end

local FACT = { [0] = 1, 1, 2, 6, 24, 120 }

local BY_SIZE   -- BY_SIZE[n] = list of count vectors of n dice (n = 0..5)
local OUTCOMES  -- OUTCOMES[n] = list of { c = counts, p = probability }
local HANDS     -- BY_SIZE[5]
local HAND_DICE -- HAND_DICE[key] = sorted dice array of that 5-dice hand

local function build_tables()
    if BY_SIZE then return end
    BY_SIZE, OUTCOMES, HAND_DICE = {}, {}, {}
    for n = 0, 5 do BY_SIZE[n], OUTCOMES[n] = {}, {} end
    local c = { 0, 0, 0, 0, 0, 0 }
    local function rec(f, left_total)
        if f > 6 then
            local n = c[1] + c[2] + c[3] + c[4] + c[5] + c[6]
            local copy = { c[1], c[2], c[3], c[4], c[5], c[6] }
            local list = BY_SIZE[n]
            list[#list + 1] = copy
            -- Probability of rolling exactly this multiset with n dice.
            local ways = FACT[n]
            for i = 1, 6 do ways = ways / FACT[copy[i]] end
            local out = OUTCOMES[n]
            out[#out + 1] = { c = copy, p = ways / (6 ^ n) }
            return
        end
        for k = 0, left_total do
            c[f] = k
            rec(f + 1, left_total - k)
        end
        c[f] = 0
    end
    rec(1, 5)
    HANDS = BY_SIZE[5]
    for _, h in ipairs(HANDS) do
        local d = {}
        for f = 1, 6 do for _ = 1, h[f] do d[#d + 1] = f end end
        HAND_DICE[key_of(h)] = d
    end
end

-- Calls fn(sub) for every sub-multiset of counts c (fn may not keep `sub`).
local function each_sub(c, fn)
    local s = { 0, 0, 0, 0, 0, 0 }
    local function rec(f)
        if f > 6 then return fn(s) end
        for k = 0, c[f] do
            s[f] = k
            rec(f + 1)
        end
        s[f] = 0
    end
    rec(1)
end

-- ---------------------------------------------------------------------------
-- End-of-turn value
-- ---------------------------------------------------------------------------

-- Value of finishing the turn with `dice` for player p: the best box's
-- (points + Yahtzee bonus - box worth + upper-bonus pull). Returns the value
-- and that box.
local function hand_value(board, p, dice)
    local Board = getmetatable(board)
    local upper = Board.upperSum(p)
    local need  = Board.UPPER_BONUS_AT - upper
    local bonus = board:bonusFor(p, dice)
    local best_v, best_cat = -math.huge, nil
    for _, cat in ipairs(Board.CATEGORIES) do
        local pts = board:scoreFor(cat, p, dice)
        if pts then
            local v = pts + bonus - BOX_WORTH[cat]
            local face = Board.UPPER_FACE[cat]
            if face and need > 0 then
                v = v + PARAMS.par_weight * (pts - 3 * face)
                if pts >= need then v = v + PARAMS.bonus_reach end
            end
            if v > best_v then best_v, best_cat = v, cat end
        end
    end
    return best_v, best_cat
end

-- Expected value of each keep, given rolls_left rolls still to come.
-- Returns EV[key(keep)] for every keep of 0..5 dice.
local function keep_values(board, p, rolls_left)
    build_tables()
    -- V[key(hand)] = value of holding `hand` with r rolls to go; r = 0 first.
    local V = {}
    for _, h in ipairs(HANDS) do
        V[key_of(h)] = (hand_value(board, p, HAND_DICE[key_of(h)]))
    end
    local EV
    for _ = 1, rolls_left do
        EV = {}
        for k = 0, 5 do
            local outs = OUTCOMES[5 - k]
            for _, keep in ipairs(BY_SIZE[k]) do
                local kk, e = key_of(keep), 0
                for _, o in ipairs(outs) do
                    e = e + o.p * V[kk + key_of(o.c)]
                end
                EV[kk] = e
            end
        end
        -- Value of each hand with one more roll available: its best keep
        -- (keeping all five means stopping here).
        local V2 = {}
        for _, h in ipairs(HANDS) do
            local best = -math.huge
            each_sub(h, function(s)
                local e = EV[key_of(s)]
                if e > best then best = e end
            end)
            V2[key_of(h)] = best
        end
        V = V2
    end
    return EV
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- The dice the current (computer) player should hold before the next roll,
-- as a held[1..5] boolean list, and whether rolling is worth it at all
-- (false: score now). Only meaningful once the turn's first roll is made.
function AI.chooseHolds(board)
    local p = board:currentPlayer()
    local hand = board.countsOf(board.dice)
    local EV = keep_values(board, p, board.rolls_left)
    local best_e, best_keep = -math.huge, nil
    -- Ties go to the first keep found; each_sub visits small keeps first, so
    -- a tie prefers rerolling more dice -- harmless, the values are equal.
    each_sub(hand, function(s)
        local e = EV[key_of(s)]
        if e > best_e + 1e-9 then
            best_e, best_keep = e, { s[1], s[2], s[3], s[4], s[5], s[6] }
        end
    end)
    local held, left = {}, { best_keep[1], best_keep[2], best_keep[3],
                             best_keep[4], best_keep[5], best_keep[6] }
    local all = true
    for i = 1, #board.dice do
        local f = board.dice[i]
        if left[f] > 0 then
            held[i] = true
            left[f] = left[f] - 1
        else
            held[i] = false
            all = false
        end
    end
    return held, not all
end

-- The box the current (computer) player should score its dice in.
function AI.chooseCategory(board)
    local _, cat = hand_value(board, board:currentPlayer(), board.dice)
    return cat
end

-- Play one whole turn for the current player (simulation helper).
function AI.playTurn(board)
    board:roll()
    while board.rolls_left > 0 do
        local held, reroll = AI.chooseHolds(board)
        if not reroll then break end
        board:setHolds(held)
        board:roll()
    end
    return board:score(AI.chooseCategory(board))
end

AI.BOX_WORTH = BOX_WORTH
AI.PARAMS    = PARAMS
AI._handValue = hand_value

return AI
