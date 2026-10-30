local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
package.path = DIR .. "?.lua;" .. package.path

-- A board whose dice are set by hand instead of rolled.
local function rigged(Board, players)
    local queue = {}
    local b = Board:new{ players = players, rng = function()
        return table.remove(queue, 1) or 1
    end }
    b.feed = function(faces) for _, f in ipairs(faces) do queue[#queue + 1] = f end end
    return b
end

describe("YahtzeeBoard", function()
    local Board

    setup(function()
        Board = require("board")
    end)

    describe("raw scores", function()
        local S
        setup(function() S = Board.rawScore end)

        it("upper boxes sum the matching face", function()
            assert.are.equal(3, S("ones", { 1, 1, 1, 4, 5 }))
            assert.are.equal(0, S("twos", { 1, 1, 1, 4, 5 }))
            assert.are.equal(18, S("sixes", { 6, 6, 6, 4, 5 }))
        end)

        it("of-a-kind boxes need the count and score the sum", function()
            assert.are.equal(17, S("three_kind", { 3, 3, 3, 4, 4 }))
            assert.are.equal(0, S("three_kind", { 3, 3, 2, 4, 4 }))
            assert.are.equal(14, S("four_kind", { 2, 2, 2, 2, 6 }))
            assert.are.equal(0, S("four_kind", { 2, 2, 2, 5, 6 }))
            assert.are.equal(25, S("four_kind", { 5, 5, 5, 5, 5 }))
        end)

        it("full house is exactly three plus two", function()
            assert.are.equal(25, S("full_house", { 2, 2, 3, 3, 3 }))
            assert.are.equal(0, S("full_house", { 3, 3, 3, 3, 2 }))
            assert.are.equal(0, S("full_house", { 4, 4, 4, 4, 4 }))   -- only via Joker
        end)

        it("straights", function()
            assert.are.equal(30, S("small_straight", { 1, 2, 3, 4, 6 }))
            assert.are.equal(30, S("small_straight", { 3, 4, 5, 6, 3 }))
            assert.are.equal(0, S("small_straight", { 1, 2, 3, 5, 6 }))
            assert.are.equal(40, S("large_straight", { 2, 3, 4, 5, 6 }))
            assert.are.equal(30, S("small_straight", { 2, 3, 4, 5, 6 }))
            assert.are.equal(0, S("large_straight", { 1, 2, 3, 4, 6 }))
        end)

        it("yahtzee and chance", function()
            assert.are.equal(50, S("yahtzee", { 6, 6, 6, 6, 6 }))
            assert.are.equal(0, S("yahtzee", { 6, 6, 6, 6, 5 }))
            assert.are.equal(15, S("chance", { 1, 2, 3, 4, 5 }))
        end)
    end)

    describe("turn flow", function()
        it("starts with three rolls and blank dice", function()
            local b = Board:new()
            assert.are.equal(3, b.rolls_left)
            assert.is_false(b:hasRolled())
            for i = 1, 5 do assert.are.equal(0, b.dice[i]) end
        end)

        it("cannot hold or score before the first roll", function()
            local b = Board:new()
            assert.is_false(b:toggleHold(1))
            assert.is_nil(b:score("chance"))
        end)

        it("held dice keep their face on the next roll", function()
            local b = rigged(Board)
            b.feed{ 6, 6, 1, 2, 3 }
            b:roll()
            b:toggleHold(1); b:toggleHold(2)
            b.feed{ 6, 5, 4 }
            b:roll()
            assert.are.same({ 6, 6, 6, 5, 4 }, b.dice)
            assert.are.equal(1, b.rolls_left)
        end)

        it("allows three rolls at most, and no holding after the last", function()
            local b = Board:new()
            assert.is_true(b:roll())
            assert.is_true(b:roll())
            assert.is_true(b:roll())
            assert.is_false(b:roll())
            assert.is_false(b:canHold())
        end)

        it("scoring passes to the next player, then the next round", function()
            local b = rigged(Board, { { ai = false }, { ai = true } })
            b.feed{ 1, 2, 3, 4, 5 }
            b:roll()
            assert.are.equal(40, b:score("large_straight"))
            assert.are.equal(2, b.current)
            assert.are.equal(1, b.round)
            assert.are.equal(3, b.rolls_left)
            b:roll()
            b:score("chance")
            assert.are.equal(1, b.current)
            assert.are.equal(2, b.round)
        end)

        it("refuses a box that is already filled", function()
            local b = rigged(Board)
            b:roll(); b:score("chance")
            b:roll()
            assert.is_nil(b:score("chance"))
        end)

        it("ends after 13 rounds with every box filled", function()
            math.randomseed(3)
            local b = Board:new{ players = { { ai = false }, { ai = false } } }
            local turns = 0
            while not b.game_over do
                b:roll()
                for _, cat in ipairs(Board.CATEGORIES) do
                    if b:scoreFor(cat) then b:score(cat); break end
                end
                turns = turns + 1
                assert.is_true(turns <= 26)
            end
            assert.are.equal(26, turns)
            for _, p in ipairs(b.players) do
                for _, cat in ipairs(Board.CATEGORIES) do assert.is_not_nil(p.scores[cat]) end
            end
            assert.is_false(b:roll())
        end)
    end)

    describe("bonuses", function()
        it("upper bonus at 63", function()
            local p = { scores = { ones = 3, twos = 6, threes = 9, fours = 12, fives = 15, sixes = 18 }, yahtzee_bonus = 0 }
            assert.are.equal(63, Board.upperSum(p))
            assert.are.equal(35, Board.upperBonus(p))
            assert.are.equal(98, Board.total(p))
            p.scores.ones = 2
            assert.are.equal(0, Board.upperBonus(p))
        end)

        it("an extra Yahtzee scores 100 and follows the forced Joker", function()
            local b = rigged(Board)
            local p = b:currentPlayer()
            p.scores.yahtzee = 50
            b.feed{ 4, 4, 4, 4, 4 }
            b:roll()
            -- Fours open: it is the only legal box.
            local legal = b:legalCategories()
            assert.is_true(legal.fours)
            assert.is_nil(legal.chance)
            assert.is_nil(b:scoreFor("full_house"))
            assert.are.equal(120, b:score("fours"))
            assert.are.equal(100, p.yahtzee_bonus)
        end)

        it("Joker: matching upper box filled -> any lower box at full value", function()
            local b = rigged(Board)
            local p = b:currentPlayer()
            p.scores.yahtzee, p.scores.fours = 50, 12
            b.feed{ 4, 4, 4, 4, 4 }
            b:roll()
            assert.is_nil(b:scoreFor("sixes"))
            assert.are.equal(25, b:scoreFor("full_house"))
            assert.are.equal(30, b:scoreFor("small_straight"))
            assert.are.equal(40, b:scoreFor("large_straight"))
            assert.are.equal(20, b:scoreFor("chance"))
        end)

        it("Joker: no lower box left -> any upper box for zero", function()
            local b = rigged(Board)
            local p = b:currentPlayer()
            for i = 7, 13 do p.scores[Board.CATEGORIES[i]] = 0 end
            p.scores.yahtzee, p.scores.fours = 50, 12
            b.feed{ 4, 4, 4, 4, 4 }
            b:roll()
            assert.are.equal(0, b:scoreFor("sixes"))
            assert.are.equal(100, b:score("sixes"))   -- bonus still paid
        end)

        it("no bonus when the Yahtzee box was zeroed", function()
            local b = rigged(Board)
            b:currentPlayer().scores.yahtzee = 0
            b.feed{ 2, 2, 2, 2, 2 }
            b:roll()
            assert.are.equal(0, b:bonusFor())
            assert.are.equal(10, b:score("twos"))
        end)
    end)

    describe("leaders", function()
        it("reports ties", function()
            local b = Board:new{ players = { { ai = false }, { ai = false }, { ai = true } } }
            b.players[1].scores.chance = 20
            b.players[2].scores.chance = 20
            b.players[3].scores.chance = 10
            local l, best = b:leaders()
            assert.are.same({ 1, 2 }, l)
            assert.are.equal(20, best)
        end)
    end)

    describe("serialize / load", function()
        it("round-trips a game in progress", function()
            local b = rigged(Board, { { ai = false }, { ai = true } })
            b.feed{ 5, 5, 5, 5, 5 }
            b:roll(); b:score("yahtzee")
            b.feed{ 1, 2, 3, 4, 6 }
            b:roll(); b:toggleHold(2)
            local b2 = Board:new()
            assert.is_true(b2:load(b:serialize()))
            assert.are.same(b.dice, b2.dice)
            assert.are.same(b.held, b2.held)
            assert.are.equal(b.rolls_left, b2.rolls_left)
            assert.are.equal(2, b2.current)
            assert.is_true(b2.players[2].ai)
            assert.are.equal(50, b2.players[1].scores.yahtzee)
            assert.are.equal(Board.total(b.players[1]), Board.total(b2.players[1]))
        end)

        it("rejects invalid data", function()
            local b = Board:new()
            assert.is_false(b:load(nil))
            assert.is_false(b:load({}))
            assert.is_false(b:load({ players = {}, dice = {} }))
        end)
    end)
end)
